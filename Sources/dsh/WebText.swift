import Foundation

enum WebText {

    /// Crude but effective HTML → readable text. Strips scripts/styles/tags, decodes entities.
    static func htmlToText(_ html: String) -> String {
        var s = String(html.prefix(2_000_000))
        // `head` first: it contains most of the script/style bulk, so removing
        // it up front spares the later passes from rescanning discarded markup.
        for tag in ["head", "script", "style", "noscript", "svg"] {
            // The closer is optional: a page with unterminated <script> tags
            // made the lazy `.*?</tag>` rescan the whole remainder per opener
            // (320KB of openers took 52s). Stopping at EOF instead is linear.
            s = s.replacingOccurrences(of: "(?is)<\(tag)[^>]*>.*?(?:</\(tag)>|$)", with: " ",
                                       options: .regularExpression)
        }
        s = s.replacingOccurrences(of: "(?i)<br\\s*/?>", with: "\n", options: .regularExpression)
        s = s.replacingOccurrences(of: "(?i)</(p|div|li|h[1-6]|tr|section|article|header|footer|ul|ol|table)>", with: "\n\n", options: .regularExpression)
        s = s.replacingOccurrences(of: "(?i)<li[^>]*>", with: "- ", options: .regularExpression)
        s = s.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
        s = decodeEntities(s)
        s = s.replacingOccurrences(of: "[ \\t]+", with: " ", options: .regularExpression)
        s = s.replacingOccurrences(of: "\n{3,}", with: "\n\n", options: .regularExpression)
        return s.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func decodeEntities(_ s: String) -> String {
        var out = s
        // Numeric entities FIRST: decoding &amp; before them would turn
        // &amp;#60; into &#60; and then a second pass would decode it to <.
        // Build the result in one pass over the match ranges: replacing each
        // match in place re-copied the whole string per entity (120k entities
        // took 1.75s, and scraped pages routinely carry that many).
        if let rx = try? NSRegularExpression(pattern: "&#(x?[0-9a-fA-F]+);") {
            let ns = out as NSString
            let matches = rx.matches(in: out, range: NSRange(location: 0, length: ns.length))
            if !matches.isEmpty {
                var result = ""
                result.reserveCapacity(ns.length)
                var cursor = 0
                for m in matches {
                    if m.range.location > cursor {
                        result += ns.substring(with: NSRange(location: cursor, length: m.range.location - cursor))
                    }
                    let hex = ns.substring(with: m.range(at: 1))
                    let val: UInt32? = hex.hasPrefix("x") ? UInt32(hex.dropFirst(), radix: 16) : UInt32(hex)
                    if let v = val, let scalar = Unicode.Scalar(v) {
                        result.append(Character(scalar))
                    } else {
                        result += ns.substring(with: m.range) // not a valid scalar: keep verbatim
                    }
                    cursor = m.range.location + m.range.length
                }
                if cursor < ns.length { result += ns.substring(from: cursor) }
                out = result
            }
        }
        let named: [String: String] = ["&amp;": "&", "&lt;": "<", "&gt;": ">", "&quot;": "\"",
                                       "&#39;": "'", "&apos;": "'", "&nbsp;": " ", "&mdash;": "—",
                                       "&ndash;": "–", "&hellip;": "…", "&laquo;": "«", "&raquo;": "»"]
        // &amp; last so &amp;lt; decodes once to &lt;, not <.
        for k in ["&lt;", "&gt;", "&quot;", "&#39;", "&apos;", "&nbsp;", "&mdash;", "&ndash;", "&hellip;", "&laquo;", "&raquo;", "&amp;"] {
            if let v = named[k] { out = out.replacingOccurrences(of: k, with: v) }
        }
        return out
    }

    /// DuckDuckGo HTML search. No API key needed.
    static func search(query: String, limit: Int) async throws -> String {
        var comps = URLComponents(string: "https://html.duckduckgo.com/html/")!
        comps.queryItems = [URLQueryItem(name: "q", value: query)]
        var req = URLRequest(url: comps.url!, timeoutInterval: 20)
        req.setValue("Mozilla/5.0 (Macintosh) dsh-proper/0.2", forHTTPHeaderField: "User-Agent")
        let (data, resp) = try await URLSession.shared.data(for: req)
        guard let http = resp as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw ToolError.failed("search failed: HTTP \((resp as? HTTPURLResponse)?.statusCode ?? -1)")
        }
        guard let html = String(data: data, encoding: .utf8) else { return "search failed" }

        var results: [String] = []
        // result links: class="result__a" href="//duckduckgo.com/l/?uddg=<encoded>&rut=..."
        let linkRx = try NSRegularExpression(pattern: "<a[^>]+class=\"result__a\"[^>]+href=\"([^\"]+)\"[^>]*>(.*?)</a>")
        let snipRx = try NSRegularExpression(pattern: "class=\"result__snippet\"[^>]*>(.*?)</a>")
        let ns = html as NSString
        let links = linkRx.matches(in: html, range: NSRange(location: 0, length: ns.length))
        let snips = snipRx.matches(in: html, range: NSRange(location: 0, length: ns.length))
        for (i, m) in links.enumerated() {
            if results.count >= limit { break }
            var href = ns.substring(with: m.range(at: 1))
            if let r = href.range(of: "uddg=") {
                var u = String(href[r.upperBound...])
                if let amp = u.firstIndex(of: "&") { u = String(u[..<amp]) }
                href = u.removingPercentEncoding ?? href
            }
            var title = ns.substring(with: m.range(at: 2))
            title = decodeEntities(title.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression))
            var snip = ""
            let nextLinkLoc = i + 1 < links.count ? links[i + 1].range.location : ns.length
            if let sm = snips.first(where: { $0.range.location > m.range.location && $0.range.location < nextLinkLoc }) {
                snip = ns.substring(with: sm.range(at: 1))
                snip = decodeEntities(snip.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression))
                    .trimmingCharacters(in: .whitespaces)
            }
            results.append("\(results.count + 1). \(title)\n   \(href)\n   \(snip)")
        }
        return results.isEmpty ? "no results" : results.joined(separator: "\n\n")
    }
}
