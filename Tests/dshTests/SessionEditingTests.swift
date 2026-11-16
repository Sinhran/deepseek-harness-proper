import XCTest
@testable import DSHCore

/// Branch / Rewind / Regenerate core. Rewind writes to the user's files, so the
/// restore rules are pinned case by case.
final class SessionEditingTests: XCTestCase {

    /// Three turns. Each user message starts a turn; change turn stamps follow
    /// the agent loop (a turn's changes carry that turn's user-message number).
    private func threeTurns() -> Session {
        var s = Session(title: "Fix the parser", workspace: "/w")
        s.wire = [WireMessage(role: .system, content: "sys")]
        for (i, t) in [1, 3, 5].enumerated() {
            s.messages.append(Message(role: .user, content: "ask \(i)", turn: t))
            s.messages.append(Message(role: .assistant, content: "answer \(i)", turn: t))
            s.messages.append(Message(role: .assistant, content: "done \(i)", turn: t + 1))
            s.wire.append(WireMessage(role: .user, content: "ask \(i)"))
            s.wire.append(WireMessage(role: .assistant, content: "answer \(i)"))
            s.changes.append(FileChange(path: "/w/f\(i).txt", before: "b\(i)", after: "a\(i)", turn: t + 1))
        }
        return s
    }

    func testTurnLookup() {
        let s = threeTurns()
        XCTAssertEqual(SessionEditing.turnCount(s), 3)
        XCTAssertEqual(SessionEditing.turn(of: s.messages[4].id, in: s), 1)
        XCTAssertEqual(SessionEditing.turn(of: s.messages[0].id, in: s), 0)
        XCTAssertNil(SessionEditing.turn(of: UUID(), in: s))
    }

    func testTruncateCutsMessagesWireAndChangesTogether() throws {
        let s = threeTurns()
        let (kept, dropped) = try XCTUnwrap(SessionEditing.truncated(s, keepingTurns: 0))
        XCTAssertEqual(kept.messages.map(\.content), ["ask 0", "answer 0", "done 0"])
        XCTAssertEqual(kept.wire.map(\.role), [.system, .user, .assistant], "system prompt survives")
        XCTAssertEqual(kept.changes.map(\.path), ["/w/f0.txt"])
        XCTAssertEqual(dropped.map(\.path), ["/w/f1.txt", "/w/f2.txt"], "oldest first")

        let none = try XCTUnwrap(SessionEditing.truncated(s, keepingTurns: -1))
        XCTAssertTrue(none.session.messages.isEmpty)
        XCTAssertEqual(none.session.wire.map(\.role), [.system])

        let all = try XCTUnwrap(SessionEditing.truncated(s, keepingTurns: 2))
        XCTAssertEqual(all.session.messages.count, 9); XCTAssertTrue(all.dropped.isEmpty)
    }

    func testTruncateRefusesWhenWireAndMessagesDisagree() {
        var s = threeTurns()
        s.wire.removeLast(2) // one user turn missing from the wire
        XCTAssertNil(SessionEditing.truncated(s, keepingTurns: 0), "a blind cut would desync them")
    }

    func testBranchIsIndependentWithNumberedTitle() throws {
        let s = threeTurns()
        let b = try XCTUnwrap(SessionEditing.branch(s, throughTurn: 1))
        XCTAssertNotEqual(b.id, s.id)
        XCTAssertEqual(b.title, "Fix the parser (2)")
        XCTAssertEqual(b.workspace, s.workspace)
        XCTAssertEqual(SessionEditing.turnCount(b), 2)
        XCTAssertEqual(SessionEditing.branchTitle("Fix the parser (2)"), "Fix the parser (3)")
        XCTAssertEqual(SessionEditing.branchTitle("Ratio (a)"), "Ratio (a) (2)", "only numeric suffixes count")
    }

    // MARK: restore plan

    func testRestoreUsesFirstBeforeWhenFileStillMatchesLastAfter() {
        // Two edits to one file across dropped turns: restore to the state
        // before the first, but only because the file holds the last edit.
        let changes = [FileChange(path: "/w/a", before: "v0", after: "v1", turn: 3, created: false, restorable: true),
                       FileChange(path: "/w/a", before: "v1", after: "v2", turn: 5, created: false, restorable: true)]
        let plan = SessionEditing.restorePlan(for: changes) { _ in "v2" }
        XCTAssertEqual(plan.restores.map(\.path), ["/w/a"])
        XCTAssertEqual(plan.restores.first?.action, .write("v0"))
        XCTAssertTrue(plan.conflicts.isEmpty)
    }

    func testFileChangedSinceIsLeftAlone() {
        let changes = [FileChange(path: "/w/a", before: "v0", after: "v1", turn: 3)]
        let plan = SessionEditing.restorePlan(for: changes) { _ in "v1 plus my own edit" }
        XCTAssertTrue(plan.restores.isEmpty, "never overwrite work done since")
        XCTAssertEqual(plan.conflicts, ["/w/a"])
        let gone = SessionEditing.restorePlan(for: changes) { _ in nil }
        XCTAssertEqual(gone.conflicts, ["/w/a"], "a deleted file is a change too")
    }

    func testCreatedFileIsDeletedNotEmptied() {
        let created = [FileChange(path: "/w/new", before: "", after: "x", turn: 3, created: true, restorable: true)]
        XCTAssertEqual(SessionEditing.restorePlan(for: created) { _ in "x" }.restores.first?.action, .delete)
        // A legacy record (no `created` flag) with empty `before` is not
        // assumed to be new: it is emptied, never deleted.
        let legacy = [FileChange(path: "/w/old", before: "", after: "x", turn: 3)]
        XCTAssertEqual(SessionEditing.restorePlan(for: legacy) { _ in "x" }.restores.first?.action, .write(""))
    }

    func testNonUTF8OriginalIsNeverWrittenBack() {
        let binary = [FileChange(path: "/w/img", before: "(non-UTF-8 content, 9 bytes)", after: "x", turn: 3,
                                 created: false, restorable: false)]
        let plan = SessionEditing.restorePlan(for: binary) { _ in "x" }
        XCTAssertTrue(plan.restores.isEmpty)
        XCTAssertEqual(plan.unrestorable, ["/w/img"], "the placeholder text must not replace the real bytes")
    }

    func testApplyRestoresAndDeletesOnDisk() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("dsh-rewind-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        let edited = dir.appendingPathComponent("edited.txt").path
        let created = dir.appendingPathComponent("created.txt").path
        try "agent wrote this".write(toFile: edited, atomically: true, encoding: .utf8)
        try "brand new".write(toFile: created, atomically: true, encoding: .utf8)
        let dropped = [FileChange(path: edited, before: "original", after: "agent wrote this", turn: 3, created: false, restorable: true),
                       FileChange(path: created, before: "", after: "brand new", turn: 3, created: true, restorable: true)]
        let plan = SessionEditing.restorePlan(for: dropped, read: SessionEditing.readText)
        XCTAssertTrue(SessionEditing.apply(plan).isEmpty)
        XCTAssertEqual(SessionEditing.readText(edited), "original")
        XCTAssertFalse(FileManager.default.fileExists(atPath: created))
    }

    // The confirmation must say exactly what happens, in correct English.
    func testRewindSummaryWording() {
        var plan = SessionEditing.RestorePlan()
        plan.restores = [("/w/a.swift", .write("x"))]
        plan.conflicts = ["/w/b.swift"]
        let text = MainWindowController.rewindSummary(plan: plan, laterTurns: 2, regenerating: false)
        XCTAssertTrue(text.contains("The 2 later turns are removed"))
        XCTAssertTrue(text.contains("Restores 1 file the agent changed: a.swift."))
        XCTAssertTrue(text.contains("Leaves 1 file as it is because it changed since: b.swift."))
        XCTAssertTrue(text.contains("Commands the agent ran aren't undone."), "never imply shell effects are undone")
        let one = MainWindowController.rewindSummary(plan: .init(), laterTurns: 1, regenerating: false)
        XCTAssertTrue(one.contains("The later turn is removed"))
        plan.conflicts = ["/w/b", "/w/c"]
        XCTAssertTrue(MainWindowController.rewindSummary(plan: plan, laterTurns: 1, regenerating: true)
            .contains("Leaves 2 files as they are because they changed since"))
    }
}
