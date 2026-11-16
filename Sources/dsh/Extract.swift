import Foundation
import PDFKit

/// Thread-safe cancellation probe for work that runs outside a task's
/// executor (the blocking pool), where `Task.isCancelled` always reads
/// false. `withTaskCancellationHandler` flips it from `onCancel`.
final class CancelFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var flag = false
    func cancel() { lock.lock(); flag = true; lock.unlock() }
    var isCancelled: Bool { lock.lock(); defer { lock.unlock() }; return flag }
}

enum Extract {

    static func attachmentInfo(for url: URL) -> Attachment {
        let ext = url.pathExtension.lowercased()
        return Attachment(path: url.path, name: url.lastPathComponent, kind: kind(ext))
    }

    static func attachment(for url: URL, cancel: CancelFlag? = nil) -> Attachment {
        let ext = url.pathExtension.lowercased()
        var a = attachmentInfo(for: url)
        a.extractedText = extract(url: url, ext: ext, cancel: cancel)
        return a
    }

    static func attachments(for urls: [URL]) async -> [Attachment] {
        // Extraction parks threads in process waits, so it runs on the
        // blocking pool — never the cooperative pool. Task.isCancelled is
        // invisible there, so cancellation travels as an explicit flag.
        let cancel = CancelFlag()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                Shell.blockingQueue.async {
                    continuation.resume(returning: urls.map { url in
                        cancel.isCancelled ? Self.attachmentInfo(for: url)
                                           : Self.attachment(for: url, cancel: cancel)
                    })
                }
            }
        } onCancel: {
            cancel.cancel()
        }
    }

    private static func kind(_ ext: String) -> String {
        switch ext {
        case "png", "jpg", "jpeg", "gif", "webp", "heic": return "image"
        case "pdf": return "pdf"
        case "doc", "docx", "rtf", "rtfd", "odt": return "doc"
        case "xls", "xlsx", "csv", "tsv", "ods": return "sheet"
        case "ppt", "pptx", "key": return "slides"
        default: return "text"
        }
    }

    /// Cancellation probe for blocking work: the flag when the caller
    /// supplied one (off-pool extraction), else the ambient task's state.
    private static func cancelled(_ flag: CancelFlag?) -> Bool {
        flag?.isCancelled ?? Task.isCancelled
    }

    private static func extract(url: URL, ext: String, cancel: CancelFlag? = nil) -> String {
        switch ext {
        case "pdf":
            if (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0 > 20_000_000 { return "(file too large)" }
            guard let doc = PDFDocument(url: url) else { return "(could not read PDF)" }
            var out = ""
            for i in 0..<min(doc.pageCount, 100) {
                if let s = doc.page(at: i)?.string { out += s + "\n" }
            }
            return String(out.prefix(200_000))

        case "doc", "docx", "rtf", "rtfd", "odt":
            // textutil is native macOS
            let tmp = NSTemporaryDirectory() + "dsh-\(UUID().uuidString).txt"
            let p = Process(); p.executableURL = URL(fileURLWithPath: "/usr/bin/textutil")
            p.arguments = ["-convert", "txt", "-output", tmp, url.path]
            try? p.run()
            let deadline = Date().addingTimeInterval(20)
            while p.isRunning && Date() < deadline && !cancelled(cancel) { Thread.sleep(forTimeInterval: 0.05) }
            if p.isRunning { Shell.killTree(p) }
            p.waitUntilExit()
            defer { try? FileManager.default.removeItem(atPath: tmp) }
            if cancelled(cancel) { return "(extraction cancelled)" }
            if (try? URL(fileURLWithPath: tmp).resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0 > 2_000_000 {
                return "(file too large)"
            }
            guard let text = try? String(contentsOfFile: tmp, encoding: .utf8), !text.isEmpty else {
                return "(could not convert document)"
            }
            return String(text.prefix(200_000))

        case "xlsx", "pptx", "key":
            return unzipXML(url: url, ext: ext, cancel: cancel)

        case "csv", "tsv":
            if (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0 > 20_000_000 { return "(file too large)" }
            return String(((try? String(contentsOf: url, encoding: .utf8)) ?? "").prefix(200_000))

        case "png", "jpg", "jpeg", "gif", "webp", "heic":
            if let img = NSImage(contentsOf: url) {
                return "(image \(url.lastPathComponent), \(Int(img.size.width))x\(Int(img.size.height)))"
            }
            return "(could not read image)"

        default:
            // Stat before reading: contents(atPath:) would pull the whole
            // file into memory before the size check could run.
            guard let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) else {
                return "(could not read file)"
            }
            if size > 2_000_000 { return "(file too large: \(size) bytes)" }
            guard let data = FileManager.default.contents(atPath: url.path) else { return "(could not read file)" }
            if let s = String(data: data, encoding: .utf8) { return String(s.prefix(200_000)) }
            return "(binary file)"
        }
    }

    /// Office Open XML: list the archive, then unzip + strip tags the members
    /// that carry document order. Uses /usr/bin/unzip (native).
    private static func unzipXML(url: URL, ext: String, cancel: CancelFlag? = nil) -> String {
        if (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0 > 20_000_000 { return "(file too large)" }
        let members = zipMembers(url: url, cancel: cancel)
        guard !members.isEmpty else { return "(could not list archive contents)" }
        let wanted: [String]
        switch ext {
        case "xlsx":
            wanted = members.filter { $0.hasPrefix("xl/worksheets/") && $0.hasSuffix(".xml") }
                .sorted { sheetOrder($0) < sheetOrder($1) }
        case "pptx":
            wanted = members.filter { $0.hasPrefix("ppt/slides/slide") && $0.hasSuffix(".xml") }
                .sorted { slideOrder($0) < slideOrder($1) }
        case "key": return "(Keynote: export as PDF for text extraction)"
        default:
            wanted = members.filter { $0 == "word/document.xml" }
        }
        let sharedStrings: [String]
        if ext == "xlsx", let member = members.first(where: { $0 == "xl/sharedStrings.xml" }),
           let data = unzipData(url: url, member: member, cap: 2_000_000, cancel: cancel) {
            sharedStrings = XLSXText.sharedStrings(data)
        } else {
            sharedStrings = []
        }
        var out = ""
        var sawContent = false
        for m in wanted {
            guard let data = unzipData(url: url, member: m, cap: 2_000_000, cancel: cancel), !data.isEmpty else { continue }
            let text: String
            if ext == "xlsx" {
                text = XLSXText.worksheet(data, sharedStrings: sharedStrings)
            } else {
                guard let xml = String(data: data, encoding: .utf8) else { continue }
                let stripped = xml.replacingOccurrences(of: "<[^>]+>", with: " ", options: .regularExpression)
                text = WebText.decodeEntities(stripped).replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            }
            if !text.trimmingCharacters(in: .whitespaces).isEmpty { sawContent = true }
            out += text + "\n"
            if out.count > 200_000 { break }
        }
        if out.isEmpty { return "(no extractable content)" }
        return String(out.prefix(200_000)) + (sawContent ? "" : "\n(no readable text found)")
    }

    /// Member names inside the zip, via `unzip -Z1`.
    private static func zipMembers(url: URL, cancel: CancelFlag? = nil) -> [String] {
        guard let data = runUnzip(url: url, arguments: ["-Z1", url.path], cap: 2_000_000, cancel: cancel),
              data.count < 2_000_000 else { return [] }
        guard let s = String(data: data, encoding: .utf8) else { return [] }
        // Members starting with "-" must never reach an unzip argv position:
        // info-zip would read them as options. The wanted-filters keep such
        // names out today; this keeps it true if a filter ever widens.
        return s.components(separatedBy: "\n").filter { !$0.isEmpty && !$0.hasPrefix("-") }
    }

    private static func unzipData(url: URL, member: String, cap: Int, cancel: CancelFlag? = nil) -> Data? {
        runUnzip(url: url, arguments: ["-p", url.path, member], cap: cap, cancel: cancel)
    }

    private static func runUnzip(url: URL, arguments: [String], cap: Int, cancel: CancelFlag? = nil) -> Data? {
        let process = Process(), pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
        process.arguments = arguments
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return nil }
        let output = Shell.OutputBuffer(cap: cap)
        let drains = DispatchGroup()
        Shell.drain(pipe.fileHandleForReading, into: output, group: drains)
        let deadline = Date().addingTimeInterval(20)
        while process.isRunning && Date() < deadline && !cancelled(cancel) { Thread.sleep(forTimeInterval: 0.02) }
        if process.isRunning { Shell.killTree(process) }
        process.waitUntilExit()
        _ = drains.wait(timeout: .now() + 3)
        guard !cancelled(cancel), process.terminationStatus == 0 else { return nil }
        let data = output.data()
        return data.count < cap ? data : nil
    }

    private static func slideOrder(_ member: String) -> Int {
        Int(member.replacingOccurrences(of: #"\D"#, with: "", options: .regularExpression)) ?? 0
    }
    private static func sheetOrder(_ member: String) -> Int {
        Int(member.replacingOccurrences(of: #"\D"#, with: "", options: .regularExpression)) ?? 0
    }
}

enum XLSXText {
    static func sharedStrings(_ data: Data) -> [String] {
        guard let xml = String(data: data, encoding: .utf8) else { return [] }
        return captures(#"<si\b[^>]*>(.*?)</si>"#, in: xml).map { match in
            let item = match.last ?? ""
            return WebText.decodeEntities(captures(#"<t\b[^>]*>(.*?)</t>"#, in: item).compactMap(\.last).joined())
        }
    }

    static func worksheet(_ data: Data, sharedStrings: [String]) -> String {
        guard let xml = String(data: data, encoding: .utf8) else { return "" }
        return captures(#"<row\b[^>]*>(.*?)</row>"#, in: xml).map { match in
            let row = match.last ?? ""
            return captures(#"<c\b([^>]*?)(?:/>|>(.*?)</c>)"#, in: row).map { cell in
                let attributes = cell.count > 1 ? cell[1] : ""
                let body = cell.count > 2 ? cell[2] : ""
                let type = captures(#"\bt\s*=\s*["']([^"']+)["']"#, in: attributes).first?.last ?? ""
                let value: String
                if type == "s", let raw = captures(#"<v\b[^>]*>(.*?)</v>"#, in: body).first?.last,
                   let index = Int(raw), sharedStrings.indices.contains(index) {
                    value = sharedStrings[index]
                } else if type == "inlineStr" {
                    value = WebText.decodeEntities(captures(#"<t\b[^>]*>(.*?)</t>"#, in: body).compactMap(\.last).joined())
                } else {
                    value = WebText.decodeEntities(captures(#"<v\b[^>]*>(.*?)</v>"#, in: body).first?.last ?? "")
                }
                return value
            }.joined(separator: "\t")
        }.joined(separator: "\n")
    }

    private static func captures(_ pattern: String, in text: String) -> [[String]] {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.dotMatchesLineSeparators]) else { return [] }
        let source = text as NSString
        return regex.matches(in: text, range: NSRange(location: 0, length: source.length)).map { match in
            (0..<match.numberOfRanges).map { index in
                let range = match.range(at: index)
                return range.location == NSNotFound ? "" : source.substring(with: range)
            }
        }
    }
}
