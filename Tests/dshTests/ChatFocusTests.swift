import XCTest
import AppKit
@testable import DSHCore

/// Regression: in the empty (hero) state the empty composer dock stretched
/// over the whole chat pane and ate every click, so the editor could never
/// take focus. A click at the editor's center must hit the editor itself,
/// in both hero and docked states.
final class ChatFocusTests: XCTestCase {
    private func editorHit(_ wc: MainWindowController) -> NSView? {
        wc.window?.contentView?.layoutSubtreeIfNeeded()
        let tv = wc.chat.input.textView
        let center = NSPoint(x: tv.bounds.midX, y: tv.bounds.midY)
        // hitTest takes the point in the receiver's superview coordinates.
        guard let superview = wc.chat.view.superview else { return nil }
        return wc.chat.view.hitTest(tv.convert(center, to: superview))
    }

    func testDefaultFocusTargetIsComposer() {
        // firstResponder only lands if the window can become key; a bare
        // xctest process is never active unless we make it so. NSApp is nil
        // until NSApplication.shared is created, so go through .shared.
        NSApplication.shared.activate(ignoringOtherApps: true)
        let wc = MainWindowController()
        defer { wc.shutdown(); wc.window?.close() }
        wc.showWindow(nil)
        RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        XCTAssertTrue(wc.window?.initialFirstResponder === wc.chat.input.textView,
                      "window's initial first responder must be the composer, not the sidebar Search")
        XCTAssertTrue(wc.window?.firstResponder === wc.chat.input.textView,
                      "composer must hold first responder after show, got \(String(describing: wc.window?.firstResponder))")
    }

    func testEditorClickableInHeroState() {
        let wc = MainWindowController()
        defer { wc.shutdown(); wc.window?.close() }
        XCTAssertTrue(editorHit(wc) === wc.chat.input.textView,
                      "click at hero composer center must hit the text view, got \(String(describing: editorHit(wc)))")
    }

    func testEditorClickableInDockedState() {
        let wc = MainWindowController()
        defer { wc.shutdown(); wc.window?.close() }
        var s = Session(title: "t", workspace: "/tmp")
        s.messages = [Message(role: .user, content: "hi")]
        wc.chat.load(session: s)
        XCTAssertTrue(editorHit(wc) === wc.chat.input.textView,
                      "click at docked composer center must hit the text view, got \(String(describing: editorHit(wc)))")
    }
}
