import XCTest
import AppKit
@testable import DSHCore

/// Session lifecycle: ⌘N always opens a fresh memory-only blank (never the
/// last persisted blank, never a sidebar row), the blank is saved only on
/// first activity, and a selected session row exposes a visible delete
/// button plus a Delete-key path (no right-click required).
final class SessionLifecycleTests: XCTestCase {
    private func makeController() -> MainWindowController {
        let wc = MainWindowController()
        wc.window?.contentView?.layoutSubtreeIfNeeded()
        return wc
    }

    func testNewSessionIsFreshAndUnsaved() {
        let wc = makeController()
        let store = SessionStore.shared
        let persistedBefore = store.sessions.count

        wc.newSession()
        let first = wc.activeSessionID
        XCTAssertTrue(wc.session.messages.isEmpty, "new session starts blank")
        XCTAssertFalse(store.sessions.contains { $0.id == first },
                       "an unused blank must not be persisted")

        // A second ⌘N must not land on the previous blank again.
        wc.newSession()
        XCTAssertNotEqual(wc.activeSessionID, first, "each ⌘N creates a new blank")
        XCTAssertEqual(store.sessions.count, persistedBefore,
                       "unused blanks never reach the store")
        wc.shutdown()
    }

    func testDraftIsSavedOnFirstActivity() {
        let wc = makeController()
        let store = SessionStore.shared
        wc.newSession()
        let draft = wc.session
        XCTAssertFalse(store.sessions.contains { $0.id == draft.id })

        wc.persistIfDraft(draft)
        XCTAssertTrue(store.sessions.contains { $0.id == draft.id },
                      "first activity adopts the draft into the store")
        store.flush()
        XCTAssertNotNil(store.load(draft.id), "adopted draft is written to disk")

        // Re-persisting a tracked session is a no-op, not a duplicate.
        let count = store.sessions.count
        wc.persistIfDraft(draft)
        XCTAssertEqual(store.sessions.count, count)
        store.delete(draft.id)
        wc.shutdown()
    }

    func testSelectedRowExposesVisibleDeleteButton() {
        let wc = makeController()
        let store = SessionStore.shared
        let a = store.newSession(workspace: "/tmp")
        let b = store.newSession(workspace: "/tmp")
        wc.sidebar.selectedSession = a.id
        wc.sidebar.reload()

        let deleteButtons = collectButtons(in: wc.sidebar.view)
            .filter { $0.toolTip == "Delete session" }
        XCTAssertGreaterThanOrEqual(deleteButtons.count, 2, "every row carries a delete button")
        XCTAssertEqual(deleteButtons.filter { !$0.isHidden }.count, 1,
                       "exactly the selected row shows its delete button without hover")
        XCTAssertFalse(deleteButtons.allSatisfy { $0.isHidden })
        store.delete(a.id); store.delete(b.id)
        wc.shutdown()
    }

    func testDeleteKeyDeletesSelectedSession() throws {
        let wc = makeController()
        let store = SessionStore.shared
        let s = store.newSession(workspace: "/tmp")
        wc.sidebar.selectedSession = s.id
        wc.sidebar.reload()

        var deleted: UUID?
        wc.sidebar.onDeleteSession = { deleted = $0 }
        let event = try XCTUnwrap(NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: [],
            timestamp: 0, windowNumber: 0, context: nil,
            characters: "\u{7f}", charactersIgnoringModifiers: "\u{7f}",
            isARepeat: false, keyCode: 51))
        wc.sidebar.keyDown(with: event)
        XCTAssertEqual(deleted, s.id, "Delete key deletes the selected session")
        store.delete(s.id)
        wc.shutdown()
    }

    func testTrashButtonDeletesItsRow() {
        let wc = makeController()
        let store = SessionStore.shared
        let s = store.newSession(workspace: "/tmp")
        wc.sidebar.selectedSession = s.id
        wc.sidebar.reload()

        var deleted: UUID?
        wc.sidebar.onDeleteSession = { deleted = $0 }
        let trash = collectButtons(in: wc.sidebar.view).first { $0.toolTip == "Delete session" && !$0.isHidden }
        XCTAssertNotNil(trash, "selected row must show a clickable trash button")
        trash?.performClick(nil)
        XCTAssertEqual(deleted, s.id, "clicking trash deletes that row's session")
        store.delete(s.id)
        wc.shutdown()
    }
}
