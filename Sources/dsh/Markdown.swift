import AppKit

/// Compact markdown → NSAttributedString renderer. Handles: headings, **bold**, *italic*,
/// `code`, ``` fenced blocks, lists (-/*, 1.), links, > quotes, --- rules. GitHub-style
/// tables are split out by `splitTables` and drawn by TableBlockView.
enum MD {

    // Compiled once: these run per line/per token, not per render.
    // try! is safe here: the patterns are compile-time constants known to be valid regexes.
    private static let headingRx = try! NSRegularExpression(pattern: "^(#{1,6})\\s+(.*)$")
    private static let hrRx = try! NSRegularExpression(pattern: "^(-{3,}|\\*{3,}|_{3,})$")
    private static let listRx = try! NSRegularExpression(pattern: "^([-*+]|\\d+\\.)\\s+(.*)$")
    /// Inline patterns in priority order; the URL group tolerates one level
    /// of balanced parentheses (Wikipedia-style links).
    private static let inlinePatterns = [
        "`([^`]+)`",
        // Lazy, so `**a *b* c**` keeps its inner italic.
        "\\*\\*(.+?)\\*\\*",
        "~~([^~]+)~~",
        "\\*([^*\\s][^*]*)\\*",
        "\\[([^\\]]+)\\]\\(((?:[^()\\\\]|\\\\.|\\([^()]*\\))+)\\)",
    ]
    private static let inlineRegexes = inlinePatterns.compactMap { try? NSRegularExpression(pattern: $0) }

    private static func firstMatch(_ rx: NSRegularExpression, in s: String) -> NSTextCheckingResult? {
        rx.firstMatch(in: s, range: NSRange(location: 0, length: (s as NSString).length))
    }

    struct Palette {
        var text = T.text
        var secondary = T.secondary
        var codeBg = T.codeBg
        var codeText = T.text
        var accent = T.accentText
        var quote = T.secondary
    }

    static func render(_ md: String, palette: Palette = Palette(), fontSize: CGFloat = 13.5) -> NSAttributedString {
        let out = NSMutableAttributedString()
        let body = NSFont.systemFont(ofSize: fontSize)
        let mono = NSFont.monospacedSystemFont(ofSize: fontSize - 0.5, weight: .regular)
        let lines = md.components(separatedBy: "\n")
        var i = 0
        var inCode = false
        var codeBuf = ""

        func flushCode() {
            let para = NSMutableParagraphStyle()
            para.paragraphSpacing = 4; para.lineSpacing = 2
            let padded = "  " + codeBuf.replacingOccurrences(of: "\n", with: "\n  ")
            out.append(NSAttributedString(string: padded + "\n", attributes: [
                .font: mono, .foregroundColor: palette.codeText,
                .backgroundColor: palette.codeBg, .paragraphStyle: para]))
            codeBuf = ""
        }

        while i < lines.count {
            let line = lines[i]
            // CommonMark allows up to 3 leading spaces on a fence.
            let lead = line.prefix(while: { $0 == " " }).count
            if lead <= 3, line.dropFirst(lead).hasPrefix("```") {
                if inCode { flushCode(); inCode = false } else { inCode = true }
                i += 1; continue
            }
            if inCode { codeBuf += line + (i < lines.count - 1 ? "\n" : ""); i += 1; continue }

            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty { out.append(NSAttributedString(string: "\n", attributes: [.font: body])); i += 1; continue }

            // headings
            if let m = Self.firstMatch(Self.headingRx, in: trimmed) {
                let source = trimmed as NSString
                let level = source.substring(with: m.range(at: 1)).count
                let text = source.substring(with: m.range(at: 2))
                let size = fontSize + CGFloat(5 - min(level, 4)) * 2
                let f = NSFont.systemFont(ofSize: size, weight: .semibold)
                out.append(inline(text, font: f, palette: palette))
                out.append(NSAttributedString(string: "\n", attributes: [.font: f]))
                i += 1; continue
            }
            // hr
            if Self.firstMatch(Self.hrRx, in: trimmed) != nil {
                out.append(NSAttributedString(string: "────────────────\n", attributes: [
                    .font: body, .foregroundColor: palette.secondary]))
                i += 1; continue
            }
            // blockquote
            if trimmed.hasPrefix(">") {
                let text = String(trimmed.dropFirst()).trimmingCharacters(in: .whitespaces)
                let para = NSMutableParagraphStyle(); para.headIndent = 12
                let attrs: [NSAttributedString.Key: Any] = [.font: body, .foregroundColor: palette.quote, .paragraphStyle: para]
                let s = NSMutableAttributedString(string: "▎ ", attributes: [.font: body, .foregroundColor: palette.accent])
                s.append(inline(text, font: body, palette: palette, extra: attrs))
                s.append(NSAttributedString(string: "\n", attributes: attrs))
                out.append(s); i += 1; continue
            }
            // lists (indent from the raw line drives nesting depth)
            let rawLine = line
            let indentSpaces = rawLine.prefix(while: { $0 == " " }).count
            let depth = min(indentSpaces / 2, 4)
            if let m = Self.firstMatch(Self.listRx, in: trimmed) {
                let tns = trimmed as NSString
                let markerRaw = tns.substring(with: m.range(at: 1))
                let marker = markerRaw.hasSuffix(".") ? markerRaw : "•"
                let rest = tns.substring(with: m.range(at: 2))
                let para = NSMutableParagraphStyle(); para.headIndent = 18 + CGFloat(depth) * 16; para.paragraphSpacing = 2
                let indent = depth > 0 ? String(repeating: "  ", count: depth) : ""
                let str = NSMutableAttributedString(string: indent + marker + " ", attributes: [.font: body, .foregroundColor: palette.accent, .paragraphStyle: para])
                str.append(inline(rest, font: body, palette: palette, extra: [.paragraphStyle: para]))
                str.append(NSAttributedString(string: "\n", attributes: [.font: body, .paragraphStyle: para]))
                out.append(str); i += 1; continue
            }

            out.append(inline(trimmed, font: body, palette: palette))
            out.append(NSAttributedString(string: "\n", attributes: [.font: body]))
            i += 1
        }
        if inCode { flushCode() }
        return out
    }

    /// Inline: `code`, **bold**, *italic*, [links](url), ~~strike~~
    private static func inline(_ text: String, font: NSFont, palette: Palette,
                               extra: [NSAttributedString.Key: Any] = [:]) -> NSAttributedString {
        let result = NSMutableAttributedString()
        var attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: palette.text]
        extra.forEach { attrs[$0.key] = $0.value }
        let mono = NSFont.monospacedSystemFont(ofSize: font.pointSize - 0.5, weight: .regular)
        // (pattern, groupCount) in no priority order: the earliest match wins.
        let regexes = Self.inlineRegexes
        var rest = text
        while !rest.isEmpty {
            let ns = rest as NSString
            var best: (NSTextCheckingResult, Int)? = nil
            for (idx, rx) in regexes.enumerated() {
                if let m = rx.firstMatch(in: rest, range: NSRange(location: 0, length: ns.length)),
                   best == nil || m.range.location < best!.0.range.location {
                    best = (m, idx)
                }
            }
            guard let (m, kind) = best else { appendPlain(result, rest, attrs); break }
            appendPlain(result, ns.substring(to: m.range.location), attrs)
            let inner = m.numberOfRanges > 1 ? ns.substring(with: m.range(at: 1)) : ""
            var a = attrs
            switch kind {
            case 0:
                a[.font] = mono; a[.backgroundColor] = palette.codeBg
                result.append(NSAttributedString(string: " \(inner) ", attributes: a))
            // Emphasis recurses, so `code`, links, and other emphasis inside
            // it still render; inner traits stack on the outer font.
            case 1:
                // Semibold, as before; keeps an outer italic.
                var bold = NSFont.systemFont(ofSize: font.pointSize, weight: .semibold)
                if font.fontDescriptor.symbolicTraits.contains(.italic) {
                    bold = NSFont(descriptor: bold.fontDescriptor.withSymbolicTraits(
                        bold.fontDescriptor.symbolicTraits.union(.italic)), size: font.pointSize) ?? bold
                }
                result.append(inline(inner, font: bold, palette: palette, extra: without(a, .font)))
            case 2:
                a[.strikethroughStyle] = NSUnderlineStyle.single.rawValue
                result.append(inline(inner, font: font, palette: palette, extra: without(a, .font)))
            case 3:
                let italic = NSFont(descriptor: font.fontDescriptor.withSymbolicTraits(
                    font.fontDescriptor.symbolicTraits.union(.italic)), size: font.pointSize) ?? font
                result.append(inline(inner, font: italic, palette: palette, extra: without(a, .font)))
            default:
                let url = m.numberOfRanges > 2 ? ns.substring(with: m.range(at: 2)) : ""
                // Only real web URLs become links; other schemes render
                // the literal source rather than eating the target.
                if let u = URL(string: url), let scheme = u.scheme?.lowercased(),
                   scheme == "http" || scheme == "https" {
                    a[.link] = u; a[.foregroundColor] = palette.accent
                    result.append(inline(inner, font: font, palette: palette, extra: a))
                } else {
                    appendPlain(result, ns.substring(with: m.range), attrs)
                }
            }
            let end = m.range.location + m.range.length
            rest = end < ns.length ? ns.substring(from: end) : ""
        }
        return result
    }

    private static func without(_ attrs: [NSAttributedString.Key: Any],
                                _ key: NSAttributedString.Key) -> [NSAttributedString.Key: Any] {
        var copy = attrs; copy[key] = nil; return copy
    }

    private static func appendPlain(_ out: NSMutableAttributedString, _ s: String, _ attrs: [NSAttributedString.Key: Any]) {
        if !s.isEmpty { out.append(NSAttributedString(string: s, attributes: attrs)) }
    }
}

// MARK: - Tables (GitHub-flavored)

extension MD {
    struct Table: Equatable {
        var header: [String]
        var alignments: [NSTextAlignment]
        var rows: [[String]]
    }

    enum Segment: Equatable {
        case prose(String)
        /// `source` is the table's original markdown (for caching and copy).
        case table(Table, source: String)
    }

    /// Inline markdown (`code`, **bold**, *italic*, links, ~~strike~~) for
    /// text that isn't a whole block, e.g. a table cell.
    static func renderInline(_ text: String, fontSize: CGFloat, weight: NSFont.Weight = .regular,
                             palette: Palette = Palette()) -> NSAttributedString {
        inline(text, font: NSFont.systemFont(ofSize: fontSize, weight: weight), palette: palette)
    }

    /// Splits prose into prose and table segments. A table is a header row
    /// with pipes, then a delimiter row (`|---|:--:|`) with the same number of
    /// cells, then body rows up to the first blank or pipe-less line. Text
    /// without tables comes back as one unchanged prose segment.
    static func splitTables(_ text: String) -> [Segment] {
        let lines = text.components(separatedBy: "\n")
        var out: [Segment] = []
        var prose: [String] = []
        var i = 0
        while i < lines.count {
            let header = lines[i]
            if i + 1 < lines.count, header.contains("|"),
               let alignments = delimiterAlignments(lines[i + 1]),
               case let headerCells = cells(header), headerCells.count == alignments.count {
                if !prose.isEmpty { out.append(.prose(prose.joined(separator: "\n"))); prose = [] }
                var rows: [[String]] = []
                var j = i + 2
                while j < lines.count, lines[j].contains("|"),
                      !lines[j].trimmingCharacters(in: .whitespaces).isEmpty {
                    var row = cells(lines[j])
                    // GitHub pads short rows and drops extra cells.
                    if row.count < headerCells.count { row += Array(repeating: "", count: headerCells.count - row.count) }
                    rows.append(Array(row.prefix(headerCells.count)))
                    j += 1
                }
                let source = lines[i..<j].joined(separator: "\n")
                out.append(.table(Table(header: headerCells, alignments: alignments, rows: rows), source: source))
                i = j
                continue
            }
            prose.append(header)
            i += 1
        }
        if !prose.isEmpty { out.append(.prose(prose.joined(separator: "\n"))) }
        return out.isEmpty ? [.prose(text)] : out
    }

    /// Cells of one table row: outer pipes optional, `\|` is a literal pipe.
    static func cells(_ line: String) -> [String] {
        var s = line.trimmingCharacters(in: .whitespaces)
        if s.hasPrefix("|") { s.removeFirst() }
        if s.hasSuffix("|") && !s.hasSuffix("\\|") { s.removeLast() }
        var cells: [String] = [], current = ""
        var escaped = false
        for ch in s {
            if escaped { current.append(ch == "|" ? "|" : "\\\(ch)"); escaped = false; continue }
            if ch == "\\" { escaped = true; continue }
            if ch == "|" { cells.append(current); current = ""; continue }
            current.append(ch)
        }
        if escaped { current.append("\\") }
        cells.append(current)
        return cells.map { $0.trimmingCharacters(in: .whitespaces) }
    }

    /// Column alignments if `line` is a delimiter row, else nil.
    private static func delimiterAlignments(_ line: String) -> [NSTextAlignment]? {
        guard line.contains("-") else { return nil }
        let parts = cells(line)
        var result: [NSTextAlignment] = []
        for p in parts {
            guard !p.isEmpty, p.allSatisfy({ $0 == "-" || $0 == ":" }), p.contains("-"),
                  !p.dropFirst().dropLast().contains(":") else { return nil }
            switch (p.hasPrefix(":"), p.hasSuffix(":")) {
            case (true, true): result.append(.center)
            case (false, true): result.append(.right)
            default: result.append(.natural)
            }
        }
        return result
    }
}
