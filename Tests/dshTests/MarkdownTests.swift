import AppKit
import XCTest
@testable import DSHCore

final class MarkdownTests: XCTestCase {
    // MARK: tables

    func testTableIsSplitOutWithAlignments() {
        let md = """
        Intro line.

        | Tool | Calls | Status |
        |:-----|------:|:------:|
        | `read` | 12 | ok |
        | edit | 3 |
        After.
        """
        let segments = MD.splitTables(md)
        XCTAssertEqual(segments.count, 3)
        XCTAssertEqual(segments.first, .prose("Intro line.\n"))
        guard case let .table(table, source) = segments[1] else { return XCTFail("no table: \(segments)") }
        XCTAssertEqual(table.header, ["Tool", "Calls", "Status"])
        XCTAssertEqual(table.alignments, [.natural, .right, .center])
        XCTAssertEqual(table.rows, [["`read`", "12", "ok"], ["edit", "3", ""]], "short rows are padded")
        XCTAssertTrue(source.hasPrefix("| Tool |") && source.hasSuffix("| edit | 3 |"))
        XCTAssertEqual(segments.last, .prose("After."))
    }

    func testPipesWithoutDelimiterRowStayProse() {
        let md = "a | b\nnot a delimiter\n| x |"
        XCTAssertEqual(MD.splitTables(md), [.prose(md)])
        XCTAssertEqual(MD.splitTables("| a | b |\n|---|"), [.prose("| a | b |\n|---|")],
                       "delimiter must have one cell per header cell")
    }

    func testEscapedPipeAndOptionalOuterPipes() {
        XCTAssertEqual(MD.cells("| a \\| b | c |"), ["a | b", "c"])
        XCTAssertEqual(MD.cells("a | b"), ["a", "b"])
        guard case let .table(t, _) = MD.splitTables("a | b\n--- | ---\n1 | 2").first else { return XCTFail() }
        XCTAssertEqual(t.rows, [["1", "2"]])
    }

    func testTableBlockViewHasOneCellPerEntry() {
        guard case let .table(t, src) = MD.splitTables("| a | b |\n|---|---|\n| 1 | **2** |").first else { return XCTFail() }
        let view = TableBlockView(table: t, source: src)
        view.frame = NSRect(x: 0, y: 0, width: 600, height: 100)
        view.layoutSubtreeIfNeeded()
        let fields = allSubviews(view).compactMap { $0 as? NSTextField }.map(\.stringValue)
        XCTAssertEqual(fields, ["a", "b", "1", "2"], "cells render inline markdown, not literal **")
    }

    func testTableCellsCarryColumnAlignment() {
        guard case let .table(t, src) = MD.splitTables("| a | b | c |\n|:--|:-:|--:|\n| 1 | 2 | 3 |").first else { return XCTFail() }
        let view = TableBlockView(table: t, source: src)
        view.frame = NSRect(x: 0, y: 0, width: 600, height: 100)
        view.layoutSubtreeIfNeeded()
        let body = allSubviews(view).compactMap { $0 as? NSTextField }.suffix(3)
        let aligns = body.map { ($0.attributedStringValue.attribute(.paragraphStyle, at: 0, effectiveRange: nil) as? NSParagraphStyle)?.alignment }
        XCTAssertEqual(aligns, [.natural, .center, .right], "alignment lives in the attributed string")
    }

    // MARK: nested inline

    func testCodeInsideBoldKeepsCodeSpan() {
        let out = MD.render("**Use `foo` here**")
        XCTAssertEqual(out.string, "Use  foo  here\n", "no literal backticks")
        let ns = out.string as NSString
        let codeFont = out.attribute(.font, at: ns.range(of: "foo").location, effectiveRange: nil) as? NSFont
        XCTAssertTrue(codeFont?.fontDescriptor.symbolicTraits.contains(.monoSpace) ?? false, "foo is a code span")
        let useFont = out.attribute(.font, at: 0, effectiveRange: nil) as? NSFont
        XCTAssertTrue(useFont?.fontDescriptor.symbolicTraits.contains(.bold) ?? false, "outer text stays bold")
    }

    func testItalicInsideBoldIsBoldItalic() {
        let out = MD.render("**a *b* c**")
        XCTAssertEqual(out.string, "a b c\n")
        let f = out.attribute(.font, at: 2, effectiveRange: nil) as? NSFont
        let traits = f?.fontDescriptor.symbolicTraits ?? []
        XCTAssertTrue(traits.contains(.bold) && traits.contains(.italic), "b is bold italic")
    }

    func testAdjacentBoldSpansStaySeparate() {
        let out = MD.render("**a** and **b**")
        XCTAssertEqual(out.string, "a and b\n")
        let mid = out.attribute(.font, at: 2, effectiveRange: nil) as? NSFont
        XCTAssertFalse(mid?.fontDescriptor.symbolicTraits.contains(.bold) ?? true, "' and ' is not bold")
    }

    private func allSubviews(_ v: NSView) -> [NSView] { v.subviews + v.subviews.flatMap(allSubviews) }
}
