import Foundation

/// Conversation controls over a Session: Branch, Rewind, Regenerate.
///
/// Unit of action is a completed TURN: one user message plus everything the
/// agent did in response, up to the next user message. (The official client's
/// Branch works on the same unit: "Branch into a new conversation", offered on
/// the last message of a completed turn.) Every turn starts with exactly one
/// `.user` entry in `messages` and in `wire`, so "keep turns 0...k" is a cut at
/// the (k+1)-th user entry in both.
///
/// Pure and UI-free: planning is separate from applying, so a confirmation can
/// show exactly what a rewind will touch before anything is written.
enum SessionEditing {

    /// Index of each turn's user message in `messages`.
    static func turnStarts(_ s: Session) -> [Int] {
        s.messages.indices.filter { s.messages[$0].role == .user }
    }

    static func turnCount(_ s: Session) -> Int { turnStarts(s).count }

    /// The turn (0-based) a message belongs to.
    static func turn(of messageID: UUID, in s: Session) -> Int? {
        guard let i = s.messages.firstIndex(where: { $0.id == messageID }) else { return nil }
        return turnStarts(s).lastIndex(where: { $0 <= i })
    }

    /// `s` keeping turns 0...k (k = -1 keeps none), plus the file changes made
    /// in the dropped turns, oldest first. Nil when messages and wire disagree
    /// on the number of turns: cutting either one blind would desync them.
    static func truncated(_ s: Session, keepingTurns k: Int) -> (session: Session, dropped: [FileChange])? {
        let starts = turnStarts(s)
        let wireStarts = s.wire.indices.filter { s.wire[$0].role == .user }
        guard starts.count == wireStarts.count, k >= -1, k < starts.count else { return nil }
        guard k + 1 < starts.count else { return (s, []) } // nothing after turn k
        var out = s
        let cutMessage = starts[k + 1]
        // Changes are stamped with the loop turn they happened in; the dropped
        // turn's user message carries the first of those turn numbers.
        let cutTurn = s.messages[cutMessage].turn
        out.messages = Array(s.messages[..<cutMessage])
        out.wire = Array(s.wire[..<wireStarts[k + 1]])
        out.changes = s.changes.filter { $0.turn < cutTurn }
        out.updated = Date()
        return (out, s.changes.filter { $0.turn >= cutTurn })
    }

    /// "Title" -> "Title (2)", "Title (2)" -> "Title (3)".
    static func branchTitle(_ title: String) -> String {
        if let open = title.range(of: " (", options: .backwards), title.hasSuffix(")"),
           let n = Int(title[open.upperBound..<title.index(before: title.endIndex)]) {
            return "\(title[..<open.lowerBound]) (\(n + 1))"
        }
        return "\(title) (2)"
    }

    /// A new, independent session holding turns 0...k. Same workspace and
    /// model; files are not touched (a branch shares the working tree).
    static func branch(_ s: Session, throughTurn k: Int) -> Session? {
        guard var copy = truncated(s, keepingTurns: k)?.session else { return nil }
        copy.id = UUID()
        copy.title = branchTitle(s.title)
        copy.created = Date(); copy.updated = Date()
        copy.scheduledTaskID = nil
        copy.running = false
        return copy
    }

    // MARK: file restore

    struct RestorePlan: Equatable {
        enum Action: Equatable { case write(String), delete }
        /// Files to put back, one action per path.
        var restores: [(path: String, action: Action)] = []
        /// Changed since the agent last wrote them (by you or a command):
        /// left exactly as they are.
        var conflicts: [String] = []
        /// No exact prior text on record (the original was not UTF-8).
        var unrestorable: [String] = []

        static func == (a: RestorePlan, b: RestorePlan) -> Bool {
            a.restores.map(\.path) == b.restores.map(\.path)
                && a.restores.map(\.action) == b.restores.map(\.action)
                && a.conflicts == b.conflicts && a.unrestorable == b.unrestorable
        }
        var isEmpty: Bool { restores.isEmpty && conflicts.isEmpty && unrestorable.isEmpty }
    }

    /// For each file the dropped changes touched: restore it to what it was
    /// before the FIRST dropped change, but only if it still holds exactly what
    /// the LAST dropped change wrote. Anything else means someone changed it
    /// since, and overwriting would destroy that work.
    /// `read` returns a file's current UTF-8 text, or nil if it is missing or
    /// not text.
    static func restorePlan(for dropped: [FileChange], read: (String) -> String?) -> RestorePlan {
        var plan = RestorePlan()
        var order: [String] = []
        var byPath: [String: [FileChange]] = [:]
        for c in dropped {
            if byPath[c.path] == nil { order.append(c.path) }
            byPath[c.path, default: []].append(c)
        }
        for path in order {
            guard let changes = byPath[path], let first = changes.first, let last = changes.last else { continue }
            guard read(path) == last.after else { plan.conflicts.append(path); continue }
            if first.created == true { plan.restores.append((path, .delete)); continue }
            guard first.restorable != false else { plan.unrestorable.append(path); continue }
            plan.restores.append((path, .write(first.before)))
        }
        return plan
    }

    /// Current UTF-8 text of a file, or nil if missing or not text.
    static func readText(_ path: String) -> String? {
        FileManager.default.contents(atPath: path).flatMap { String(data: $0, encoding: .utf8) }
    }

    /// Apply a plan. Returns the paths that failed, with reasons.
    @discardableResult
    static func apply(_ plan: RestorePlan) -> [String] {
        var failures: [String] = []
        for (path, action) in plan.restores {
            do {
                switch action {
                case .write(let text): try text.write(toFile: path, atomically: true, encoding: .utf8)
                case .delete: try FileManager.default.removeItem(atPath: path)
                }
            } catch {
                failures.append("\((path as NSString).lastPathComponent): \(error.localizedDescription)")
            }
        }
        return failures
    }
}
