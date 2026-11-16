import AppKit
import XCTest
@testable import DSHCore

/// Long prose is split at blank lines into separately cached labels, so
/// streaming re-renders only the tail. It must look exactly like one label.
final class ProseChunkingTests: XCTestCase {
    private func longProse(_ paragraphs: Int) -> String {
        (0..<paragraphs).map { i in
            "Paragraph \(i): the agent **read** `Tools.swift`, checked the *redirect* guard, and kept going with enough words to wrap twice."
                + (i % 3 == 0 ? "\n- a list item\n- another item" : "")
        }.joined(separator: "\n\n")
    }

    private func labels(in view: NSView) -> [WrappingLabel] {
        view.subviews.flatMap { ($0 as? WrappingLabel).map { [$0] } ?? labels(in: $0) }
    }

    private func layout(_ v: MessageView) {
        v.frame = NSRect(x: 0, y: 0, width: 760, height: 2000)
        v.layoutSubtreeIfNeeded()
    }

    func testLongProseIsChunkedWithoutChangingHeight() {
        let text = longProse(60)
        XCTAssertGreaterThan(text.count, MessageView.chunkThreshold)
        let view = MessageView(message: Message(role: .assistant, content: text))
        layout(view)
        let chunks = labels(in: view).filter { $0.attributedStringValue.length > 0 }
        XCTAssertGreaterThan(chunks.count, 2, "long prose becomes several labels")
        let width = chunks[0].frame.width

        let single = WrappingLabel()
        single.frame = NSRect(x: 0, y: 0, width: width, height: 10)
        single.attributedStringValue = MD.render(text, fontSize: 14)
        let chunked = chunks.reduce(0) { $0 + $1.intrinsicContentSize.height }
        XCTAssertEqual(chunked, single.intrinsicContentSize.height, accuracy: 1,
                       "chunks stacked flush measure the same as one label")
        // At a seam the blank line is the previous label's trailing newline,
        // so compare visible text, not whitespace.
        let visible = { (s: String) in s.filter { !$0.isWhitespace } }
        XCTAssertEqual(visible(chunks.map(\.stringValue).joined()), visible(single.stringValue),
                       "no text lost or duplicated at seams")
        // Stack view coordinates aren't flipped: the next chunk sits below.
        for (a, b) in zip(chunks, chunks.dropFirst()) {
            let ra = a.convert(a.bounds, to: nil), rb = b.convert(b.bounds, to: nil)
            XCTAssertEqual(ra.minY - rb.maxY, 0, accuracy: 0.5, "chunks sit flush")
        }
    }

    func testStreamingReusesFinishedChunks() {
        let view = MessageView(message: Message(role: .assistant, content: ""), live: true)
        view.appendText(longProse(40))
        view.finish(); layout(view)
        let before = labels(in: view)
        XCTAssertGreaterThan(before.count, 1)

        view.appendText(" More words on the last paragraph.")
        view.finish(); layout(view)
        let after = labels(in: view)
        XCTAssertTrue(before.first === after.first, "a finished chunk is reused, not re-rendered")
        XCTAssertTrue(after.last?.stringValue.contains("More words on the last paragraph.") ?? false)
    }

    func testShortProseStaysOneLabel() {
        let view = MessageView(message: Message(role: .assistant, content: longProse(3)))
        layout(view)
        XCTAssertEqual(labels(in: view).filter { $0.attributedStringValue.length > 0 }.count, 1)
    }
}
