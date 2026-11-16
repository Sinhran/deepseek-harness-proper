import Foundation

enum DiffOp { case equal(String), add(String), remove(String) }

struct DiffHunk {
    var oldStart: Int
    var newStart: Int
    var ops: [DiffOp]
}

enum DiffEngine {

    /// Line-level diff via LCS DP. Fine for files up to a few thousand lines.
    static func diff(old: String, new: String, context: Int = 3) -> [DiffHunk] {
        let context = max(0, context)
        let a = lines(old)
        let b = lines(new)
        // Trim common prefix/suffix first for speed — but guard on the
        // TRIMMED sizes, so a huge identical head/tail does not force the
        // fallback when the changed middle is small.
        var aStart = 0, bStart = 0
        var aEnd = a.count, bEnd = b.count
        while aStart < aEnd && bStart < bEnd && a[aStart] == b[bStart] { aStart += 1; bStart += 1 }
        while aEnd > aStart && bEnd > bStart && a[aEnd-1] == b[bEnd-1] { aEnd -= 1; bEnd -= 1 }
        let asub = Array(a[aStart..<aEnd]), bsub = Array(b[bStart..<bEnd])
        let n = asub.count, m = bsub.count
        if n > 8000 || m > 8000 || n * m > 4_000_000 {
            return [DiffHunk(oldStart: 1, newStart: 1, ops: [.remove("(file too large to diff inline: \(a.count) to \(b.count) lines)")])]
        }
        var ops: [(DiffOp, Int, Int)] = [] // (op, oldLineNo, newLineNo)
        if n == 0 && m == 0 {
            // identical inside
        } else {
            var dp = [Int](repeating: 0, count: (n + 1) * (m + 1))
            func at(_ i: Int, _ j: Int) -> Int { dp[i * (m + 1) + j] }
            func set(_ i: Int, _ j: Int, _ v: Int) { dp[i * (m + 1) + j] = v }
            for i in stride(from: n - 1, through: 0, by: -1) {
                for j in stride(from: m - 1, through: 0, by: -1) {
                    set(i, j, asub[i] == bsub[j] ? at(i+1, j+1) + 1 : max(at(i+1, j), at(i, j+1)))
                }
            }
            var i = 0, j = 0
            var oL = aStart + 1, nL = bStart + 1
            while i < n && j < m {
                if asub[i] == bsub[j] { ops.append((.equal(asub[i]), oL, nL)); i += 1; j += 1; oL += 1; nL += 1 }
                else if at(i+1, j) >= at(i, j+1) { ops.append((.remove(asub[i]), oL, nL)); i += 1; oL += 1 }
                else { ops.append((.add(bsub[j]), oL, nL)); j += 1; nL += 1 }
            }
            while i < n { ops.append((.remove(asub[i]), oL, nL)); i += 1; oL += 1 }
            while j < m { ops.append((.add(bsub[j]), oL, nL)); j += 1; nL += 1 }
        }
        if ops.isEmpty { return [] }

        // Group into hunks: changes separated by more than 2*context equal
        // lines split; each hunk keeps at most `context` equals on both sides.
        let changeIdx = ops.indices.filter { if case .equal = ops[$0].0 { return false }; return true }
        guard let firstChange = changeIdx.first, let lastChange = changeIdx.last else { return [] }
        var hunks: [DiffHunk] = []
        var hunkStart = max(0, firstChange - context)
        var idx = firstChange
        while idx <= lastChange {
            // extend to last change reachable without a >2*context equal gap
            var hunkEndChange = idx
            var j = idx
            while j <= lastChange {
                if case .equal = ops[j].0 {
                    var k = j
                    while k <= lastChange, case .equal = ops[k].0 { k += 1 }
                    if k > lastChange || k - j > context * 2 { break }
                    j = k
                } else { hunkEndChange = j; j += 1 }
            }
            let hunkEnd = min(ops.count - 1, hunkEndChange + context)
            // The trimmed affixes are identical lines; the first/last hunk
            // still owes the reader `context` equal lines on that side.
            var pre: [(DiffOp, Int, Int)] = []
            if hunkStart == 0 {
                for k in max(0, aStart - context)..<aStart {
                    pre.append((.equal(a[k]), k + 1, k - aStart + bStart + 1))
                }
            }
            var post: [(DiffOp, Int, Int)] = []
            if hunkEnd == ops.count - 1 {
                for k in 0..<min(context, a.count - aEnd) {
                    post.append((.equal(a[aEnd + k]), aEnd + k + 1, bEnd + k + 1))
                }
            }
            hunks.append(makeHunk(pre + Array(ops[hunkStart...hunkEnd]) + post))
            hunkStart = hunkEnd + 1
            idx = hunkEnd + 1
            while idx <= lastChange, case .equal = ops[idx].0 { idx += 1 }
            if idx <= lastChange { hunkStart = max(hunkStart, idx - context) }
        }
        return hunks
    }

    static func lineCount(_ text: String) -> Int { lines(text).count }

    private static func lines(_ text: String) -> [String] {
        guard !text.isEmpty else { return [] }
        var result = text.components(separatedBy: "\n")
        if text.hasSuffix("\n") { result.removeLast() }
        return result
    }

    private static func makeHunk(_ items: [(DiffOp, Int, Int)]) -> DiffHunk {
        DiffHunk(oldStart: items.first?.1 ?? 1, newStart: items.first?.2 ?? 1,
                 ops: items.map { $0.0 })
    }

    /// Render hunks as attributed-friendly rows: (tag, text) for the view layer.
    static func rows(hunks: [DiffHunk]) -> [(String, String)] {
        var out: [(String, String)] = []
        for h in hunks {
            out.append(("hunk", "@@ -\(h.oldStart) +\(h.newStart) @@"))
            for op in h.ops {
                switch op {
                case .equal(let s): out.append(("ctx", "  \(s)"))
                case .add(let s): out.append(("add", "+ \(s)"))
                case .remove(let s): out.append(("del", "- \(s)"))
                }
            }
        }
        return out
    }

    static func counts(hunks: [DiffHunk]) -> (Int, Int) {
        var a = 0, r = 0
        for h in hunks { for op in h.ops {
            if case .add = op { a += 1 }; if case .remove = op { r += 1 }
        }}
        return (a, r)
    }
}
