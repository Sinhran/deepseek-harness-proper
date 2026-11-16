import AppKit
import PDFKit

/// Right-hand inspector dock: Preview / Review / Terminal / Trace panes. Their
/// buttons live in the window's top row (see `tabButtons`), with official
/// empty states here.
final class InspectorViewController: NSViewController {
    /// Preview / Review / Terminal / Trace as direct buttons. They live in
    /// the window's top row (trailing edge), not in this pane: the window
    /// places them and decides open / switch / close via `onTabPress`.
    private(set) lazy var tabButtons: [ActionButton] = Self.tabDefs.enumerated().map { i, d in
        let b = ActionButton(symbol: d.symbol, style: .icon) { [weak self] in self?.onTabPress(i) }
        b.setFixedSize(28)
        b.iconBox = 18 // top-row scale, matches the sidebar toggle
        b.tint = T.labelTertiary
        b.actsOnFirstClick = true
        b.toolTip = "\(d.name): \(d.help)"
        b.setAccessibilityLabel(d.name)
        return b
    }
    private var tabs: [ActionButton] { tabButtons }
    var onTabPress: (Int) -> Void = { _ in }
    private(set) var selectedTab = 0
    static let tabDefs: [(name: String, symbol: String, help: String)] = [
        ("Preview", "eye", "preview the latest changed file"),
        ("Review", "rectangle.stack", "review file diffs"),
        ("Terminal", "terminal", "shell commands the agent ran"),
        ("Trace", "point.3.connected.trianglepath.dotted", "the run's trajectory"),
    ]
    private var container: NSView!
    private var panes: [NSView] = []
    private var selected = 0

    private var previewPath: NSTextField!
    private var previewFullPath = ""
    private var previewBody: NSView!
    private var previewHost: NSView!
    private var previewText: NSTextView!
    private var previewEmpty: EmptyState!
    private var reviewStack: NSStackView!
    private var reviewScroll: NSScrollView!
    /// Diff text rows with their measured heights so they can be re-fit
    /// when the pane resizes instead of staying measured at a stale width.
    private var reviewRows: [(text: NSAttributedString, height: NSLayoutConstraint)] = []
    private var lastReviewWidth: CGFloat = 0
    private var reviewEmpty: EmptyState!
    private var terminalText: NSTextView!
    private var terminalScroll: NSScrollView!
    private var terminalEmpty: EmptyState!
    private var trajOutline: NSOutlineView!
    private var traceScroll: NSScrollView!
    private var traceEmpty: EmptyState!
    private var changes: [FileChange] = []
    private var sessionMessages: [Message] = []
    private var currentPreview: NSView?
    private weak var previewOpenBtn: ActionButton?
    private weak var previewHeader: NSView?
    private weak var previewDivider: NSView?

    private var contentTop = NSLayoutConstraint()
    private var contentTrailing = NSLayoutConstraint()
    private var contentSlideWidth = NSLayoutConstraint()

    /// Hold the content at `width` against the leading edge while the pane
    /// animates (mirror of the sidebar's slide).
    func beginSlide(width: CGFloat) {
        _ = view
        contentSlideWidth.constant = width
        contentTrailing.isActive = false
        contentSlideWidth.isActive = true
    }
    func endSlide() {
        _ = view
        contentSlideWidth.isActive = false
        contentTrailing.isActive = true
    }
    /// Space for the window's top row.
    func setTopInset(_ height: CGFloat) {
        _ = view
        contentTop.constant = height
    }

    /// Show `i`'s pane. Selection wash appears only while the pane is open.
    func selectTab(_ i: Int) { _ = view; select(i) }
    /// The window shows the selected wash only while the inspector is open.
    func setTabsActive(_ active: Bool) {
        for (j, b) in tabs.enumerated() { b.selected = active && j == selectedTab; b.needsDisplay = true }
    }
    /// Changed-file count on the Review button, kept current even while the
    /// inspector is closed: that is when it matters most.
    func setReviewCount(_ n: Int) {
        tabs[1].badge = n == 0 ? "" : "\(n)"
        tabs[1].setAccessibilityLabel(n == 0 ? "Review" : "Review, \(n) changed file\(n == 1 ? "" : "s")")
    }

    override func loadView() {
        let v = TintedView(T.bgBase)

        // No tab strip: the four tab buttons sit in the window's top row.
        // Content starts right under that row; no rule (the row is the header).
        container = View()
        container.translatesAutoresizingMaskIntoConstraints = false
        v.addSubview(container)
        contentTop = container.topAnchor.constraint(equalTo: v.topAnchor, constant: 38)
        NSLayoutConstraint.activate([
            contentTop,
            container.leadingAnchor.constraint(equalTo: v.leadingAnchor),
            container.trailingAnchor.constraint(equalTo: v.trailingAnchor),
            container.bottomAnchor.constraint(equalTo: v.bottomAnchor),
        ])

        panes = [buildPreview(), buildReview(), buildTerminal(), buildTrajectory()]
        for p in panes {
            container.addSubview(p)
            p.translatesAutoresizingMaskIntoConstraints = false
            NSLayoutConstraint.activate([
                p.topAnchor.constraint(equalTo: container.topAnchor),
                p.bottomAnchor.constraint(equalTo: container.bottomAnchor),
                p.leadingAnchor.constraint(equalTo: container.leadingAnchor),
                p.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            ])
            p.isHidden = true
        }
        panes[0].isHidden = false
        // The split's pane is a clipping wrapper around `v`. While sliding, v
        // keeps its full width pinned to the LEADING edge, so the narrowing
        // pane clips it from the right: it slides out instead of reflowing.
        let wrapper = NSView()
        wrapper.wantsLayer = true
        wrapper.layer?.masksToBounds = true
        wrapper.addSubview(v)
        v.translatesAutoresizingMaskIntoConstraints = false
        contentTrailing = v.trailingAnchor.constraint(equalTo: wrapper.trailingAnchor)
        contentSlideWidth = v.widthAnchor.constraint(equalToConstant: 0)
        NSLayoutConstraint.activate([
            v.leadingAnchor.constraint(equalTo: wrapper.leadingAnchor),
            contentTrailing,
            v.topAnchor.constraint(equalTo: wrapper.topAnchor),
            v.bottomAnchor.constraint(equalTo: wrapper.bottomAnchor),
        ])
        view = wrapper
    }

    private func select(_ i: Int) {
        selected = i; selectedTab = i
        for (j, p) in panes.enumerated() { p.isHidden = j != i }
        for (j, b) in tabs.enumerated() { b.selected = j == i; b.needsDisplay = true }
        // Panes skipped during live runs refresh on demand here.
        if i == 2 { rebuildTerminal() }
        if i == 3 { rebuildTrajectory(); trajOutline?.reloadData() }
    }

    // MARK: panes

    private func buildPreview() -> NSView {
        let v = View()
        previewPath = T.label("No file selected", T.mono(10.5), T.labelSecondary)
        previewPath.lineBreakMode = .byTruncatingHead
        let openBtn = ActionButton(symbol: "arrow.up.forward.app", style: .icon) { [weak self] in self?.openExternally() }
        openBtn.tint = T.labelTertiary; openBtn.toolTip = "Open in default app"
        previewOpenBtn = openBtn
        openBtn.setAccessibilityLabel("Open in default app")
        let top = horizontal([T.icon("doc", size: 12, color: T.labelTertiary), previewPath, NSView(), openBtn], spacing: 6)
        previewHeader = top
        top.edgeInsets = NSEdgeInsets(top: 0, left: 12, bottom: 0, right: 8)
        top.heightAnchor.constraint(equalToConstant: 32).isActive = true
        let divider = T.hairlineView()
        previewDivider = divider

        previewText = NSTextView()
        previewText.isEditable = false
        previewText.font = T.mono(11)
        previewText.textColor = T.text
        previewText.backgroundColor = .clear
        previewText.drawsBackground = false
        previewText.textContainerInset = NSSize(width: 12, height: 10)
        previewText.autoresizingMask = [.width]
        previewText.isVerticallyResizable = true
        previewText.textContainer?.widthTracksTextView = true
        previewText.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        let textScroll = NSScrollView()
        textScroll.documentView = previewText
        textScroll.hasVerticalScroller = true
        textScroll.scrollerStyle = .overlay
        textScroll.drawsBackground = false
        previewBody = textScroll

        previewEmpty = EmptyState(symbol: "doc", title: "Nothing to preview",
                                  subtitle: "Select a file change to inspect it.")
        previewHost = View()
        v.addSubview(top); v.addSubview(divider); v.addSubview(previewHost)
        [top, divider, previewHost].forEach { $0.translatesAutoresizingMaskIntoConstraints = false }
        NSLayoutConstraint.activate([
            top.topAnchor.constraint(equalTo: v.topAnchor),
            top.leadingAnchor.constraint(equalTo: v.leadingAnchor),
            top.trailingAnchor.constraint(equalTo: v.trailingAnchor),
            divider.topAnchor.constraint(equalTo: top.bottomAnchor),
            divider.leadingAnchor.constraint(equalTo: v.leadingAnchor),
            divider.trailingAnchor.constraint(equalTo: v.trailingAnchor),
            previewHost.topAnchor.constraint(equalTo: divider.bottomAnchor),
            previewHost.leadingAnchor.constraint(equalTo: v.leadingAnchor),
            previewHost.trailingAnchor.constraint(equalTo: v.trailingAnchor),
            previewHost.bottomAnchor.constraint(equalTo: v.bottomAnchor),
        ])
        textScroll.translatesAutoresizingMaskIntoConstraints = false
        previewHost.addSubview(textScroll)
        previewHost.addSubview(previewEmpty)
        previewEmpty.pin(to: previewHost)
        NSLayoutConstraint.activate([
            textScroll.topAnchor.constraint(equalTo: previewHost.topAnchor),
            textScroll.leadingAnchor.constraint(equalTo: previewHost.leadingAnchor),
            textScroll.trailingAnchor.constraint(equalTo: previewHost.trailingAnchor),
            textScroll.bottomAnchor.constraint(equalTo: previewHost.bottomAnchor),
        ])
        currentPreview = textScroll
        return v
    }

    private func buildReview() -> NSView {
        reviewStack = NSStackView()
        reviewStack.orientation = .vertical; reviewStack.alignment = .leading; reviewStack.spacing = 2
        reviewStack.edgeInsets = NSEdgeInsets(top: 12, left: 10, bottom: 12, right: 10)
        let rdoc = FlippedView(); rdoc.addSubview(reviewStack)
        reviewStack.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            reviewStack.topAnchor.constraint(equalTo: rdoc.topAnchor),
            reviewStack.leadingAnchor.constraint(equalTo: rdoc.leadingAnchor),
            reviewStack.trailingAnchor.constraint(equalTo: rdoc.trailingAnchor),
            reviewStack.bottomAnchor.constraint(equalTo: rdoc.bottomAnchor),
        ])
        let s = NSScrollView(); s.documentView = rdoc; s.hasVerticalScroller = true
        s.drawsBackground = false; s.scrollerStyle = .overlay
        rdoc.translatesAutoresizingMaskIntoConstraints = false
        rdoc.widthAnchor.constraint(equalTo: s.contentView.widthAnchor).isActive = true
        reviewScroll = s
        reviewEmpty = EmptyState(symbol: "rectangle.stack", title: "No changes yet",
                                 subtitle: "The agent's file edits will appear here.")
        let host = View()
        host.addSubview(s); host.addSubview(reviewEmpty)
        s.translatesAutoresizingMaskIntoConstraints = false
        s.pin(to: host); reviewEmpty.pin(to: host)
        return host
    }

    private func buildTerminal() -> NSView {
        terminalText = NSTextView()
        terminalText.isEditable = false
        terminalText.font = T.mono(10.5)
        terminalText.textColor = T.text
        terminalText.drawsBackground = false
        terminalText.textContainerInset = NSSize(width: 12, height: 10)
        terminalText.autoresizingMask = [.width]
        terminalText.isVerticallyResizable = true
        terminalText.textContainer?.widthTracksTextView = true
        terminalText.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        let s = NSScrollView(); s.documentView = terminalText; s.hasVerticalScroller = true
        s.drawsBackground = false; s.scrollerStyle = .overlay
        terminalScroll = s
        terminalEmpty = EmptyState(symbol: "terminal", title: "No commands yet",
                                   subtitle: "Shell commands the agent runs appear here.")
        let host = View()
        host.addSubview(s); host.addSubview(terminalEmpty)
        s.translatesAutoresizingMaskIntoConstraints = false
        s.pin(to: host); terminalEmpty.pin(to: host)
        return host
    }

    private func buildTrajectory() -> NSView {
        trajOutline = NSOutlineView()
        trajOutline.headerView = nil
        trajOutline.focusRingType = .none
        trajOutline.rowSizeStyle = .small
        trajOutline.backgroundColor = .clear
        trajOutline.usesAlternatingRowBackgroundColors = false
        let c1 = NSTableColumn(identifier: .init("what")); c1.width = 300
        trajOutline.addTableColumn(c1)
        trajOutline.outlineTableColumn = c1
        trajOutline.dataSource = self; trajOutline.delegate = self
        let s = NSScrollView(); s.documentView = trajOutline; s.hasVerticalScroller = true
        s.drawsBackground = false
        traceScroll = s
        traceEmpty = EmptyState(symbol: "point.3.connected.trianglepath.dotted", title: "No activity yet",
                                subtitle: "Each turn and tool call is listed here.")
        let host = View()
        host.addSubview(s); host.addSubview(traceEmpty)
        s.translatesAutoresizingMaskIntoConstraints = false
        s.pin(to: host); traceEmpty.pin(to: host)
        return host
    }

    // MARK: session

    func load(session: Session) {
        _ = view
        changes = session.changes
        sessionMessages = session.messages
        rebuildReview(); rebuildTerminal(); rebuildTrajectory()
        trajOutline?.reloadData()
        setPreviewEmpty(changes.isEmpty)
        if let last = changes.last { showPreview(path: last.path) }
    }

    /// Live-run refresh: Terminal and Trace panes must not sit stale while a
    /// job is streaming. Cheaper than load() — no review diff recompute.
    /// Only the visible pane is rebuilt; rebuilding every pane on every
    /// streamed step is O(n²) over a long session, and select() rebuilds a
    /// pane when the user switches to it.
    func refreshLive(session: Session) {
        _ = view
        sessionMessages = session.messages
        if selected == 2 { rebuildTerminal() }
        if selected == 3 { rebuildTrajectory(); trajOutline?.reloadData() }
    }

    /// Bring Review forward (from a transcript row's Review button).
    func showReview(path: String?) {
        _ = view
        select(1)
        if let path { showPreview(path: path) } // Preview follows the same file
    }

    func addChange(_ c: FileChange) {
        changes.append(c)
        rebuildReview()
        showPreview(path: c.path)
        // Stay on the tab the user is reading; the Review badge content updates in place.
    }

    // MARK: Preview

    /// Toggle the preview pane between content and its empty state. Content
    /// views swap dynamically (text/PDF/image), so both sides flip together.
    private func setPreviewEmpty(_ empty: Bool) {
        previewEmpty.isHidden = !empty
        for v in previewHost.subviews where v !== previewEmpty { v.isHidden = empty }
        if empty { previewPath.stringValue = "No file selected"; previewFullPath = "" }
        previewOpenBtn?.isEnabled = !empty
        previewHeader?.isHidden = empty
        previewDivider?.isHidden = empty
    }

    func showPreview(path: String) {
        setPreviewEmpty(false)
        // Short display path (full path stays in the tooltip): a 60-char
        // absolute path reports a ~460pt intrinsic width and forces the whole
        // inspector pane wide. Xcode shows the filename for the same reason.
        let short = URL(fileURLWithPath: path).pathComponents.suffix(2).joined(separator: "/")
        previewPath.stringValue = short.isEmpty ? path : short
        previewPath.toolTip = path
        previewFullPath = path
        let ext = (path as NSString).pathExtension.lowercased()
        // Decode off the main thread: PDF/image/full-file reads can be large.
        let token = UUID()
        previewToken = token
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            var pdf: PDFDocument?
            var image: NSImage?
            var text: String?
            let url = URL(fileURLWithPath: path)
            if let attrs = try? FileManager.default.attributesOfItem(atPath: path),
               let size = attrs[.size] as? Int, size <= 50_000_000 {
                if ext == "pdf" {
                    pdf = PDFDocument(url: url)
                } else if ["png","jpg","jpeg","gif","webp","heic"].contains(ext) {
                    image = NSImage(contentsOfFile: path)
                } else if let data = try? Data(contentsOf: url, options: .mappedIfSafe) {
                    text = String(data: data, encoding: .utf8).map { String($0.prefix(300_000)) } ?? "(binary file)"
                }
                if pdf == nil && image == nil && text == nil { text = "(missing)" }
            } else if FileManager.default.fileExists(atPath: path) {
                text = "(file too large to preview)"
            } else {
                text = "(missing)"
            }
            DispatchQueue.main.async {
                guard let self, self.previewToken == token, self.previewFullPath == path else { return }
                if let pdf {
                    let pdfView = PDFView()
                    pdfView.document = pdf; pdfView.autoScales = true
                    self.swapPreview(pdfView)
                } else if let image {
                    let imageView = NSImageView(image: image)
                    imageView.imageScaling = .scaleProportionallyUpOrDown
                    let scroll = NSScrollView()
                    scroll.documentView = imageView; scroll.drawsBackground = false
                    self.swapPreview(scroll)
                } else {
                    self.previewText.string = text ?? "(missing)"
                    self.swapPreview(nil)
                }
            }
        }
    }
    private var previewToken = UUID()

    private func swapPreview(_ v: NSView?) {
        let replacement = v ?? previewBody
        guard replacement !== currentPreview else { return }
        currentPreview?.removeFromSuperview()
        guard let replacement else { return }
        previewHost.addSubview(replacement)
        replacement.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            replacement.topAnchor.constraint(equalTo: previewHost.topAnchor),
            replacement.leadingAnchor.constraint(equalTo: previewHost.leadingAnchor),
            replacement.trailingAnchor.constraint(equalTo: previewHost.trailingAnchor),
            replacement.bottomAnchor.constraint(equalTo: previewHost.bottomAnchor),
        ])
        currentPreview = replacement
    }

    @objc private func openExternally() {
        let p = previewFullPath
        let url = URL(fileURLWithPath: p)
        guard FileManager.default.fileExists(atPath: p) else { return }
        // An agent-written executable must not launch from the UI: reveal
        // it in Finder instead so a preview click can never run code.
        if Self.mustRevealInsteadOfOpen(path: p) {
            NSWorkspace.shared.activateFileViewerSelecting([url])
        } else {
            NSWorkspace.shared.open(url)
        }
    }

    /// Extensions whose default handler runs code or follows a link even
    /// without the executable bit: a `.terminal` file runs its CommandString,
    /// `.webloc`/`.fileloc` can point at an app, scripts open in a runner.
    /// Agent-written files carry no quarantine flag, so Gatekeeper won't step in.
    static let launchableExtensions: Set<String> = [
        "app", "command", "tool", "terminal", "sh", "zsh", "bash", "csh", "ksh",
        "webloc", "inetloc", "fileloc", "url", "scpt", "scptd", "applescript",
        "workflow", "action", "shortcut", "pkg", "mpkg", "dmg", "mobileconfig",
        "prefpane", "saver", "qlgenerator", "kext", "bundle", "plugin", "osax", "jar",
    ]

    static func mustRevealInsteadOfOpen(path: String) -> Bool {
        if launchableExtensions.contains((path as NSString).pathExtension.lowercased()) { return true }
        var isDir: ObjCBool = false
        // Directories (bundles included) are never "opened" from a preview.
        if FileManager.default.fileExists(atPath: path, isDirectory: &isDir), isDir.boolValue { return true }
        return FileManager.default.isExecutableFile(atPath: path)
    }

    // MARK: Review

    private var reviewGeneration = 0

    private func rebuildReview() {
        reviewGeneration += 1 // invalidates any in-flight diff computation
        let generation = reviewGeneration
        var byPath: [String: [FileChange]] = [:]
        for c in changes { byPath[c.path, default: []].append(c) }
        let hasContent = !byPath.isEmpty
        // Changed-file count on the Review tab: edits are discoverable
        // without opening the tab, and VoiceOver hears the count too.
        setReviewCount(byPath.count)
        reviewScroll.isHidden = !hasContent
        reviewEmpty.isHidden = hasContent
        guard hasContent else {
            for v in reviewStack.arrangedSubviews { reviewStack.removeArrangedSubview(v); v.removeFromSuperview() }
            reviewRows = []
            return
        }
        // Diffing is O(n·m) LCS work; compute off the main thread and keep
        // the stale rows visible until the fresh ones are ready to swap in.
        let groups = byPath.sorted(by: { $0.key < $1.key }).compactMap {
            (path: $0.key, first: $0.value.first, last: $0.value.last)
        }
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let diffs = groups.compactMap { g -> (String, [DiffHunk])? in
                guard let first = g.first, let last = g.last else { return nil }
                return (g.path, DiffEngine.diff(old: first.before, new: last.after))
            }
            DispatchQueue.main.async {
                guard let self, self.reviewGeneration == generation else { return }
                for v in self.reviewStack.arrangedSubviews { self.reviewStack.removeArrangedSubview(v); v.removeFromSuperview() }
                self.reviewRows = []
                for (path, hunks) in diffs { self.appendReviewRow(path: path, hunks: hunks) }
            }
        }
    }

    private func appendReviewRow(path: String, hunks: [DiffHunk]) {
        let (adds, dels) = DiffEngine.counts(hunks: hunks)

        let head = ActionButton(style: .row) { [weak self] in
            self?.showPreview(path: path)
            self?.select(0)
        }
        head.title = (path as NSString).lastPathComponent
        head.symbol = "doc.text"; head.font = T.mono(11, .medium)
        head.caption = "+\(adds) −\(dels)"
        head.toolTip = path
        reviewStack.addArrangedSubview(head); reviewStack.pinRowWidth(head)
        let spacer = View(); spacer.heightAnchor.constraint(equalToConstant: 4).isActive = true
        reviewStack.addArrangedSubview(spacer); reviewStack.pinRowWidth(spacer)

        let textView = NSTextView()
        textView.isEditable = false; textView.isSelectable = true; textView.isRichText = false
        textView.drawsBackground = false; textView.backgroundColor = .clear
        textView.textContainerInset = NSSize(width: 6, height: 4)
        textView.isHorizontallyResizable = false; textView.isVerticallyResizable = false
        textView.textContainer?.widthTracksTextView = true
        textView.textContainer?.containerSize = NSSize(width: CGFloat.greatestFiniteMagnitude,
                                                       height: CGFloat.greatestFiniteMagnitude)
        textView.setAccessibilityLabel("Diff for \(path)")
        let content = NSMutableAttributedString()
        for (tag, line) in DiffEngine.rows(hunks: hunks).prefix(500) {
            let font = T.mono(10.5)
            let paragraph = NSMutableParagraphStyle()
            paragraph.lineBreakMode = .byWordWrapping
            let foreground: NSColor
            let background: NSColor?
            switch tag {
            case "add": foreground = T.diffAddText; background = T.diffAddBg
            case "del": foreground = T.diffDelText; background = T.diffDelBg
            case "hunk": foreground = T.accentText; background = nil
            default: foreground = T.labelSecondary; background = nil
            }
            var attributes: [NSAttributedString.Key: Any] = [
                .font: font, .foregroundColor: foreground, .paragraphStyle: paragraph,
            ]
            if let background { attributes[.backgroundColor] = background }
            content.append(NSAttributedString(string: line + "\n", attributes: attributes))
        }
        textView.textStorage?.setAttributedString(content)
        let width = max(reviewStack.bounds.width - 16, 240)
        lastReviewWidth = reviewStack.bounds.width
        let measured = content.boundingRect(
            with: NSSize(width: width, height: CGFloat.greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading]).height + 8
        reviewStack.addArrangedSubview(textView); reviewStack.pinRowWidth(textView)
        let height = textView.heightAnchor.constraint(equalToConstant: max(20, ceil(measured)))
        height.isActive = true
        reviewRows.append((content, height))
        let gap = View(); gap.heightAnchor.constraint(equalToConstant: 12).isActive = true
        reviewStack.addArrangedSubview(gap); reviewStack.pinRowWidth(gap)
    }

    override func viewDidLayout() {
        super.viewDidLayout()
        refitReviewRows()
    }

    /// Re-measure diff rows after a pane resize: heights captured at build
    /// time go stale when the column gets narrower or wider.
    private func refitReviewRows() {
        let w = reviewStack.bounds.width
        guard !reviewRows.isEmpty, abs(w - lastReviewWidth) > 0.5 else { return }
        lastReviewWidth = w
        let width = max(w - 16, 240)
        for row in reviewRows {
            let h = row.text.boundingRect(
                with: NSSize(width: width, height: CGFloat.greatestFiniteMagnitude),
                options: [.usesLineFragmentOrigin, .usesFontLeading]).height + 8
            row.height.constant = max(20, ceil(h))
        }
    }

    // MARK: Terminal

    private func rebuildTerminal() {
        var out = ""
        for m in sessionMessages {
            for s in m.steps where s.name == "bash" {
                let cmd = JSON.object(s.payload).str("command") ?? ""
                out += "$ \(cmd)\n\(s.result)\n\n"
            }
        }
        terminalText.string = out
        terminalScroll.isHidden = out.isEmpty
        terminalEmpty.isHidden = !out.isEmpty
    }

    // MARK: Trajectory

    /// Class, not struct: NSOutlineView tracks expansion state by item
    /// identity, which value types do not have.
    private final class TNode {
        var label: String
        var children: [TNode] = []; var detail: String = ""
        init(label: String, detail: String = "") {
            self.label = label; self.detail = detail
        }
    }
    private var trajRoots: [TNode] = []

    private func rebuildTrajectory() {
        trajRoots = []
        for m in sessionMessages {
            let node = TNode(label: m.role.rawValue.capitalized,
                             detail: m.content + (m.reasoning.isEmpty ? "" : "\n[reasoning]\n" + m.reasoning))
            for s in m.steps {
                node.children.append(TNode(label: "\(s.name) · \(s.durationMS)ms",
                                           detail: "IN \(s.payload)\nOUT \(s.result)"))
            }
            trajRoots.append(node)
        }
        traceScroll.isHidden = trajRoots.isEmpty
        traceEmpty.isHidden = !trajRoots.isEmpty
    }
}

extension InspectorViewController: NSOutlineViewDataSource, NSOutlineViewDelegate {
    func outlineView(_ o: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
        guard let node = item as? TNode else { return trajRoots.count }
        return node.children.count
    }
    func outlineView(_ o: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
        guard let node = item as? TNode else { return trajRoots[index] }
        return node.children[index]
    }
    func outlineView(_ o: NSOutlineView, isItemExpandable item: Any) -> Bool {
        ((item as? TNode)?.children.count ?? 0) > 0
    }
    func outlineView(_ o: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
        guard let node = item as? TNode else { return nil }
        let label = T.label(node.label, T.ui(11.5), T.labelSecondary)
        label.toolTip = node.detail
        return label
    }
}
