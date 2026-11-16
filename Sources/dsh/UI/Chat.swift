import AppKit

/// One conversation: an official-style header (breadcrumbs + actions), a reading column,
/// and the composer — centered hero when empty, docked at the bottom otherwise.
final class ChatViewController: NSViewController {
    let input = InputBar()
    var onSend: (String, [Attachment]) -> Bool = { _, _ in false }
    var onStop: () -> Void = {}
    var onApproval: (UUID, Bool) -> Void = { _, _ in }
    var onWorkspace: () -> Void = {}
    /// Turn actions, keyed by the turn's last assistant message.
    var onBranch: (UUID) -> Void = { _ in }
    var onRewind: (UUID) -> Void = { _ in }
    var onRegenerate: () -> Void = {}
    private var isRunning = false

    private let transcript = NSStackView()
    private let scroll = NSScrollView()
    private let workspaceCrumb = ActionButton(style: .plain)
    private let titleCrumb = T.label("New session", T.ui(13, .medium), T.labelPrimary)
    private let separator = T.label("/", T.ui(13), T.labelCaption)
    private let headerRow = NSStackView()
    private var headerHeight: NSLayoutConstraint?

    /// The header IS the titlebar row: same height, same centerline as the
    /// traffic lights. Insets keep the breadcrumbs clear of the window-edge
    /// pane toggles while a pane is closed (the window owns those metrics).
    func setTitlebarMetrics(height: CGFloat, leading: CGFloat, trailing: CGFloat) {
        _ = view
        headerHeight?.constant = height
        headerRow.edgeInsets = NSEdgeInsets(top: 0, left: leading, bottom: 0, right: trailing)
    }
    /// Internal (not private) so tests can assert on the visible status.
    let statusPill = Pill("", color: T.labelSecondary, dot: true)
    private let hero = NSView()
    private let heroStack = NSStackView()
    private let composerSlot: NSView = {
        let v = NSView(); v.translatesAutoresizingMaskIntoConstraints = false; return v
    }()
    private let dock = NSView()
    private var messages: [UUID: MessageView] = [:]
    private var approvalViews: [UUID: ApprovalView] = [:]
    private var drafts: [UUID: (String, [Attachment])] = [:]
    private var loadedSessionID: UUID?
    private var scrollPending = false
    private var keepAtBottom = true
    private var transcriptWidthCap: NSLayoutConstraint?

    /// Official metrics: chat column = clamp(680, column*0.64, 920); composer = +32.
    var contentWidth: CGFloat {
        min(920, max(680, view.bounds.width * 0.64))
    }
    var cardWidth: CGFloat { contentWidth + 32 }

    override func loadView() {
        let root = TintedView(T.bgBase)

        // MARK: header — the titlebar row itself: breadcrumbs left, status
        // right, on the traffic lights' centerline. No second header band and
        // no hairline: one row of chrome, then content. The pane toggles flank
        // this row from the window's edges (MainWindowController), so they
        // never move when panes open and close.
        workspaceCrumb.font = T.ui(13); workspaceCrumb.tint = T.labelTertiary
        workspaceCrumb.symbol = "folder"; workspaceCrumb.onPress = { [weak self] in self?.onWorkspace() }
        titleCrumb.lineBreakMode = .byTruncatingMiddle
        titleCrumb.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        statusPill.isHidden = true
        let crumbs = horizontal([workspaceCrumb, separator, titleCrumb], spacing: 4)
        headerRow.orientation = .horizontal; headerRow.alignment = .centerY; headerRow.spacing = 8
        for v in [crumbs, NSView(), statusPill] { headerRow.addArrangedSubview(v) }
        headerRow.edgeInsets = NSEdgeInsets(top: 0, left: 20, bottom: 0, right: 16)
        let header = NSView()
        header.addSubview(headerRow)
        headerRow.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            headerRow.leadingAnchor.constraint(equalTo: header.leadingAnchor),
            headerRow.trailingAnchor.constraint(equalTo: header.trailingAnchor),
            headerRow.topAnchor.constraint(equalTo: header.topAnchor),
            headerRow.bottomAnchor.constraint(equalTo: header.bottomAnchor),
        ])
        let height = header.heightAnchor.constraint(equalToConstant: 28) // window supplies the real value
        height.isActive = true; headerHeight = height
        let headerLine = T.hairlineView(color: T.borderL3)
        headerLine.isHidden = true // layout anchor only: one row of chrome, no rule under it
        root.addSubview(header); root.addSubview(headerLine)
        header.translatesAutoresizingMaskIntoConstraints = false
        headerLine.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            header.topAnchor.constraint(equalTo: root.topAnchor),
            header.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            header.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            headerLine.topAnchor.constraint(equalTo: header.bottomAnchor),
            headerLine.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            headerLine.trailingAnchor.constraint(equalTo: root.trailingAnchor),
        ])

        // MARK: transcript scroll — centered column of chat content width.
        transcript.orientation = .vertical; transcript.alignment = .leading; transcript.spacing = 22
        transcript.edgeInsets = NSEdgeInsets(top: 26, left: 0, bottom: 24, right: 0)
        let document = FlippedView()
        document.addSubview(transcript)
        transcript.translatesAutoresizingMaskIntoConstraints = false
        let fill = transcript.widthAnchor.constraint(equalTo: document.widthAnchor)
        fill.priority = .defaultHigh
        transcriptWidthCap = transcript.widthAnchor.constraint(equalToConstant: 432)
        NSLayoutConstraint.activate([
            transcript.centerXAnchor.constraint(equalTo: document.centerXAnchor),
            transcript.topAnchor.constraint(equalTo: document.topAnchor),
            transcript.bottomAnchor.constraint(equalTo: document.bottomAnchor),
            transcriptWidthCap!, fill,
        ])
        scroll.drawsBackground = false; scroll.hasVerticalScroller = true; scroll.scrollerStyle = .overlay
        scroll.documentView = document
        document.translatesAutoresizingMaskIntoConstraints = false
        document.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor).isActive = true
        root.addSubview(scroll)
        scroll.translatesAutoresizingMaskIntoConstraints = false

        // MARK: hero empty state — centered headline + workspace row + composer.
        let fish = BrandMarkView.fish(width: 34)
        let titleText = T.label("Into the Unknown", T.serif(30), T.labelPrimary)
        let titleGroup = Preview.enabled
            ? horizontal([titleText, Badge("Preview")], spacing: 7)
            : horizontal([titleText], spacing: 7)
        titleGroup.alignment = .centerY
        let headline = horizontal([fish, titleGroup], spacing: 10)
        headline.alignment = .centerY
        let sub = T.label("Ask to read, write, and run code in this workspace.", T.ui(13), T.labelSecondary)
        sub.alignment = .center

        let folderIcon = T.icon("folder", size: 16, color: T.labelPrimary)
        let wsLabel = T.label("", T.ui(13, .medium), T.labelPrimary)
        wsLabel.maximumNumberOfLines = 1
        let chevron = T.icon("chevron.down", size: 12, color: T.labelCaption)
        let wsRowContent = horizontal([folderIcon, wsLabel, chevron], spacing: 4)
        wsRowContent.edgeInsets = NSEdgeInsets(top: 0, left: 8, bottom: 0, right: 8)
        let wsRow = FocusableActionView()
        wsRow.wantsLayer = true
        wsRow.layer?.cornerRadius = 8
        wsRow.addSubview(wsRowContent)
        wsRowContent.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            wsRowContent.topAnchor.constraint(equalTo: wsRow.topAnchor),
            wsRowContent.bottomAnchor.constraint(equalTo: wsRow.bottomAnchor),
            wsRowContent.leadingAnchor.constraint(equalTo: wsRow.leadingAnchor),
            wsRowContent.trailingAnchor.constraint(equalTo: wsRow.trailingAnchor),
            wsRow.heightAnchor.constraint(equalToConstant: 28),
        ])
        wsRow.onPress = { [weak self] in self?.onWorkspace() }
        wsRow.setAccessibilityLabel("Choose workspace")
        wsRow.setAccessibilityHelp("Opens a folder picker for the session workspace")
        self.workspaceRowLabel = wsLabel
        self.workspaceRow = wsRow

        // Composer slot is re-parented between hero and dock.
        composerSlot.addSubview(input)
        input.pin(to: composerSlot)

        heroStack.orientation = .vertical; heroStack.alignment = .centerX; heroStack.spacing = 12
        heroStackWidthCap = heroStack.widthAnchor.constraint(equalToConstant: 512)
        heroStackWidthCap.priority = .required
        heroStack.addArrangedSubview(headline)
        heroStack.addArrangedSubview(sub)
        heroStack.addArrangedSubview(wsRow)
        heroStack.setCustomSpacing(6, after: headline)
        heroStack.setCustomSpacing(16, after: wsRow)
        // Width = composer card width so headline/workspace align with the card edges.
        hero.addSubview(heroStack)
        heroStack.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            heroStack.centerXAnchor.constraint(equalTo: hero.centerXAnchor),
            heroStack.centerYAnchor.constraint(equalTo: hero.centerYAnchor, constant: -20),
            heroStackWidthCap,
        ])
        let examples = horizontal([
            ActionButton("Explain this project", style: .filled) { [weak self] in
                self?.input.setDraftIfEmpty("Explain this project and how it is structured.")
            },
            ActionButton("Review my changes", style: .filled) { [weak self] in
                self?.input.setDraftIfEmpty("Review my uncommitted changes.")
            },
            ActionButton("Attach a file", style: .filled) { [weak self] in
                self?.input.setDraftIfEmpty("@")
            },
        ], spacing: 8)
        examples.alignment = .centerY
        heroStack.addArrangedSubview(examples)
        // Composer card == hero stack width: the stack cap already includes the
        // +32 card overhang, so no extra constant here (a +32 here overflowed
        // the stack and broke layout).
        slotWidthHero = composerSlot.widthAnchor.constraint(equalTo: heroStack.widthAnchor)
        hero.isHidden = true
        root.addSubview(hero)
        hero.translatesAutoresizingMaskIntoConstraints = false

        // MARK: bottom dock for the active conversation.
        root.addSubview(dock)
        dock.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            dock.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            dock.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            dock.bottomAnchor.constraint(equalTo: root.bottomAnchor),
        ])
        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: headerLine.bottomAnchor),
            scroll.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: dock.topAnchor),
            hero.topAnchor.constraint(equalTo: headerLine.bottomAnchor),
            hero.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            hero.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            hero.bottomAnchor.constraint(equalTo: root.bottomAnchor),
        ])

        input.onSend = { [weak self] text, attachments in self?.onSend(text, attachments) ?? false }
        input.onStop = { [weak self] in self?.onStop() }
        input.onAutonomyChange = { _ in NotificationCenter.default.post(name: .settingsChanged, object: nil) }
        // Explicit width anchor: the controller-managed split sizes each pane
        // to its content width (EqualBreadth wrapper==content), so chat names
        // the leftover width from live split geometry. Initial 480 keeps
        view = root
        scroll.contentView.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(self, selector: #selector(scrolled),
                                              name: NSView.boundsDidChangeNotification, object: scroll.contentView)
        setEmpty(true)
    }

    private var workspaceRowLabel: NSTextField?
    private var workspaceRow: NSView?
    private var heroStackWidthCap: NSLayoutConstraint!
    private var slotWidthHero: NSLayoutConstraint!
    private var slotDockConstraints: [NSLayoutConstraint] = []

    override func viewDidLayout() {
        super.viewDidLayout()
        updateMetrics()
    }

    /// Re-fit the pane width and content caps. Called by the window
    /// controller whenever the split's geometry might have changed —
    /// the pane's own layout alone is not a reliable trigger.
    func updateMetrics() {
        // Content caps follow the live pane width. This must never feed back
        // into pane sizing: a stale width pinned here used to cement whatever
        // transient width the sidebar had mid-transition, so the sidebar grew
        // every time the inspector was added and removed (ratchet). Pane
        // sizes belong to the split view (holding priorities) alone.
        let chatW = max(320, view.bounds.width)
        let w = min(contentWidth, max(400, chatW - 48))
        input.maxCardWidth = w + 32
        heroStackWidthCap.constant = w + 32
        transcriptWidthCap?.constant = w
    }

    @objc private func scrolled() {
        let bottom = scroll.contentView.bounds.maxY
        keepAtBottom = (scroll.documentView?.bounds.height ?? 0) - bottom < 80
    }

    private func setEmpty(_ value: Bool) {
        hero.isHidden = !value; scroll.isHidden = value
        // An empty dock has no height of its own: left visible, Auto Layout
        // stretches it over the whole pane (its top is pinned through the
        // scroll view, its bottom to the window), and the plain view then
        // eats every click meant for the hero composer. Hide it while empty.
        dock.isHidden = value
        input.heroMode = value
        // Move the composer between the hero stack and the bottom dock.
        if value {
            if composerSlot.superview !== heroStack {
                composerSlot.removeFromSuperview()
                slotDockConstraints.forEach { $0.isActive = false }
                slotDockConstraints.removeAll()
                // Keep hero order: headline, sub, workspace row, composer, examples.
                heroStack.insertArrangedSubview(composerSlot, at: min(3, heroStack.arrangedSubviews.count))
                heroStack.setCustomSpacing(10, after: composerSlot)
            }
            slotWidthHero.isActive = true
        } else {
            if composerSlot.superview !== dock {
                composerSlot.removeFromSuperview()
                slotWidthHero.isActive = false
                dock.addSubview(composerSlot)
                composerSlot.translatesAutoresizingMaskIntoConstraints = false
                slotDockConstraints = [
                    composerSlot.topAnchor.constraint(equalTo: dock.topAnchor),
                    composerSlot.bottomAnchor.constraint(equalTo: dock.bottomAnchor, constant: -10),
                    composerSlot.leadingAnchor.constraint(equalTo: dock.leadingAnchor),
                    composerSlot.trailingAnchor.constraint(equalTo: dock.trailingAnchor),
                ]
                NSLayoutConstraint.activate(slotDockConstraints)
            }
        }
        view.needsLayout = true
    }

    func load(session: Session) {
        _ = view
        // Snapshot even on a same-id reload (e.g. a workspace change):
        // restoring from an empty slot would wipe an in-progress message.
        if let prev = loadedSessionID {
            drafts[prev] = input.snapshotDraft()
        }
        loadedSessionID = session.id
        workspaceCrumb.title = (session.workspace as NSString).lastPathComponent
        workspaceCrumb.toolTip = session.workspace
        if let l = workspaceRowLabel {
            l.stringValue = (session.workspace as NSString).lastPathComponent
            l.toolTip = session.workspace
        }
        titleCrumb.stringValue = session.title
        // (workspace path shown in the hero row label above)
        messages.removeAll()
        approvalViews.removeAll()
        transcript.arrangedSubviews.forEach { transcript.removeArrangedSubview($0); $0.removeFromSuperview() }
        session.messages.forEach { append($0) }
        input.restoreDraft(drafts[session.id] ?? ("", []))
        // The error flag belongs to the session that failed. Carrying it into
        // another session suppresses that session's normal status clearing,
        // leaving a stale pill behind.
        statusIsError = false
        setEmpty(session.messages.isEmpty); setRunning(session.running)
        refreshTurnActions()
        keepAtBottom = true; scrollToBottom()
    }

    /// Forget the saved composer draft for a deleted session.
    func dropDraft(_ id: UUID) { drafts.removeValue(forKey: id) }

    func append(_ message: Message, live: Bool = false) {
        if !isViewLoaded { _ = view }
        let row = MessageView(message: message, live: live)
        messages[message.id] = row
        transcript.addArrangedSubview(row)
        row.widthAnchor.constraint(equalTo: transcript.widthAnchor).isActive = true
        setEmpty(false); scrollToBottom()
    }
    func removeMessage(_ id: UUID) {
        guard let row = messages.removeValue(forKey: id) else { return }
        transcript.removeArrangedSubview(row)
        row.removeFromSuperview()
        if messages.isEmpty && approvalViews.isEmpty { setEmpty(true) }
        refreshTurnActions()
    }

    /// Put Branch / Rewind on the last assistant message of every completed
    /// turn (a turn ends where the next user message begins), Regenerate on
    /// the latest one too. None while a run is in progress: the latest turn
    /// is not complete, and rewriting history mid-run would race the loop.
    private func refreshTurnActions() {
        let rows = transcript.arrangedSubviews.compactMap { $0 as? MessageView }
        var tails: [MessageView] = []
        var lastAssistant: MessageView?
        for row in rows {
            row.setTurnActions(nil)
            if row.role == .user {
                if let tail = lastAssistant { tails.append(tail) }
                lastAssistant = nil
            } else if row.role == .assistant {
                lastAssistant = row
            }
        }
        if let tail = lastAssistant { tails.append(tail) }
        guard !isRunning else { return }
        for (i, tail) in tails.enumerated() {
            let id = tail.messageID, latest = i == tails.count - 1
            tail.setTurnActions(.init(
                branch: { [weak self] in self?.onBranch(id) },
                rewind: latest ? nil : { [weak self] in self?.onRewind(id) },
                regenerate: latest ? { [weak self] in self?.onRegenerate() } : nil,
                alwaysVisible: latest))
        }
    }
    func assistantStart(_ id: UUID) {
        var message = Message(role: .assistant)
        message.id = id; append(message, live: true)
    }
    func appendText(_ id: UUID, _ delta: String) { messages[id]?.appendText(delta); scrollToBottom() }
    func appendReasoning(_ id: UUID, _ delta: String) { messages[id]?.appendReasoning(delta) }
    func stepStart(_ id: UUID, _ step: Step) { messages[id]?.addStep(step); scrollToBottom() }
    func stepFinish(_ id: UUID, _ step: Step) { messages[id]?.updateStep(step); scrollToBottom() }
    private var statusIsError = false
    func setRunning(_ running: Bool) {
        let changed = running != isRunning
        isRunning = running
        input.setRunning(running)
        defer { if changed { refreshTurnActions() } }
        statusPill.isHidden = !running
        if running { statusPill.title = "Working"; statusIsError = false }
        // A run that just failed keeps its error pill: clearing it in the
        // same tick as the failure event would flash it for zero frames.
        if !running { messages.values.forEach { $0.finish() }; if !statusIsError { status("") } }
    }
    func status(_ text: String, isError: Bool = false) {
        statusIsError = isError
        // Clear the text too, not just visibility: a hidden pill that keeps
        // its old title flashes stale status the next time it is shown.
        if text.isEmpty { statusPill.title = ""; statusPill.isHidden = true; return }
        statusPill.title = text
        statusPill.isHidden = false
    }
    func showApproval(name: String, summary: String, key: UUID) {
        guard approvalViews[key] == nil else { return }
        let card = ApprovalView(tool: name, summary: summary) { [weak self] ok in self?.onApproval(key, ok) }
        card.onDone = { [weak self, weak card] in
            guard let self, let card else { return }
            self.removeApprovalView(card, key: key)
        }
        approvalViews[key] = card
        transcript.addArrangedSubview(card)
        card.widthAnchor.constraint(equalTo: transcript.widthAnchor).isActive = true
        setEmpty(false)
        scrollToBottom()
    }
    func dismissApproval(key: UUID) {
        approvalViews[key]?.dismiss()
    }
    private func removeApprovalView(_ card: ApprovalView, key: UUID) {
        approvalViews.removeValue(forKey: key)
        transcript.removeArrangedSubview(card)
        card.removeFromSuperview()
    }
    func scrollToBottom() {
        guard keepAtBottom, !scrollPending else { return }
        scrollPending = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.scrollPending = false
            guard self.keepAtBottom, let doc = self.scroll.documentView else { return }
            self.view.layoutSubtreeIfNeeded()
            self.scroll.contentView.scroll(to: NSPoint(x: 0, y: max(0, doc.bounds.height - self.scroll.contentView.bounds.height)))
            self.scroll.reflectScrolledClipView(self.scroll.contentView)
        }
    }
}
