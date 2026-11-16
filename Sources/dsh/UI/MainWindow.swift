import AppKit

final class MainWindowController: NSWindowController, NSSplitViewDelegate, NSToolbarDelegate, ReviewRouting {
    let splitView = NSSplitView()
    let sidebar = SidebarViewController()
    let chat = ChatViewController()
    let inspector = InspectorViewController()
    private var inspectorAdded = false
    private var paneWidthsRestored = false
    private var paneWidthSaveWork: DispatchWorkItem?
    private var settingsWindow: SettingsWindowController?
    var activeSessionID: UUID
    /// Fresh blank created by ⌘N, held only in memory. It is adopted
    /// into the store on first activity (see persistIfDraft), so unused
    /// blanks never appear in the sidebar or on disk.
    private var draft: Session?
    private var live: [UUID: Session] = [:]
    var session: Session {
        if let s = live[activeSessionID]
            ?? draft.flatMap({ $0.id == activeSessionID ? $0 : nil })
            ?? SessionStore.shared.sessions.first(where: { $0.id == activeSessionID }) {
            return s
        }
        // Nothing matches the id (e.g. the session was deleted under us):
        // a fresh value kept in `live` so repeated reads share one identity.
        let s = Session(title: "New session", workspace: Settings.shared.workspace)
        live[activeSessionID] = s
        return s
    }
    private var loops: [UUID: AgentLoop] = [:]
    private var jobs: [UUID: Task<Void, Never>] = [:]
    private struct PendingApproval { var session: UUID; var name: String; var summary: String; var resolve: (Bool) -> Void }
    private var approvals: [UUID: PendingApproval] = [:]
    private var isShuttingDown = false
    /// First failure reported by the loop for a running job, keyed by session.
    /// Scheduled runs record this as the TaskRun message instead of sniffing
    /// rendered markdown for an error banner.
    private var runErrors: [UUID: String] = [:]
    /// apiKey/baseURL last handed to the catalog: settings changes that do
    /// not touch them must not trigger a network refresh.
    private var lastCatalogKey = ""
    private var lastCatalogBase = ""
    private var observers: [NSObjectProtocol] = []

    init() {
        let initial: Session
        if let stored = SessionStore.shared.sessions.first {
            initial = stored
        } else {
            var blank = Session(title: "New session", workspace: Settings.shared.workspace, model: Settings.shared.model)
            blank.systemPromptInit()
            initial = blank
            draft = blank
        }
        activeSessionID = initial.id
        let window = NSWindow(contentRect: .init(x: 0, y: 0, width: 1240, height: 820),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                              backing: .buffered, defer: false)
        window.title = "DeepSeek Harness"
        window.titlebarAppearsTransparent = true; window.titleVisibility = .hidden
        window.titlebarSeparatorStyle = .none
        window.backgroundColor = T.contentBg
        window.minSize = NSSize(width: 840, height: 600)
        super.init(window: window)
        installTopRow(in: window)
        PluginEngine.shared.changed = { [weak self] in
            DispatchQueue.main.async {
                self?.sidebar.reload()
                self?.updateProfiles()
            }
        }
        splitView.isVertical = true
        splitView.dividerStyle = .thin
        splitView.delegate = self
        let host = NSViewController()
        host.view = splitView
        window.contentViewController = host
        // Seed frames from the design size; showWindow() enforces exact saved
        // widths once the window has a real layout.
        let seedH: CGFloat = 788
        let seedSide = min(Settings.sidebarWidthRange.upperBound,
                           max(Settings.sidebarWidthRange.lowerBound, Settings.shared.sidebarWidth))
        sidebar.view.frame = NSRect(x: 0, y: 0, width: seedSide, height: seedH)
        chat.view.frame = NSRect(x: seedSide + 5, y: 0,
                                 width: max(480, 1240 - seedSide - 5), height: seedH)
        // One sidebar pane, no separate strip: it is inserted and removed
        // wholesale on toggle.
        splitView.addSubview(sidebar.view)
        splitView.addSubview(chat.view)
        restackHoldingPriorities()
        // The inspector is opt-in per session (⌘I or View menu) and never
        // restored at launch: it must not claim a third of the window unasked.
        inspectorAdded = false
        sidebarShown = true
        // Pin the split view to the window's content guide: autoresizing alone
        // lets transient fitting sizes strand it narrower than the window,
        // leaving a dead zone on the right.
        splitView.translatesAutoresizingMaskIntoConstraints = false
        if let guide = window.contentLayoutGuide as? NSLayoutGuide {
            NSLayoutConstraint.activate([
                splitView.leadingAnchor.constraint(equalTo: guide.leadingAnchor),
                splitView.trailingAnchor.constraint(equalTo: guide.trailingAnchor),
                // Top runs under the transparent titlebar (not the content
                // guide, which stops below it): the chat header IS the
                // titlebar row, and the sidebar runs up behind the traffic
                // lights the way Finder's does.
                splitView.topAnchor.constraint(equalTo: window.contentView?.topAnchor ?? guide.topAnchor),
                splitView.bottomAnchor.constraint(equalTo: guide.bottomAnchor),
            ])
        } else {
            splitView.autoresizingMask = [.width, .height]
        }
        window.center()
        sidebar.onSelect = { [weak self] selection in
            if case .session(let id) = selection,
               let self, let s = self.live[id] ?? SessionStore.shared.sessions.first(where: { $0.id == id }) { self.load(s) }
        }
        sidebar.onNewSession = { [weak self] in self?.newSession() }
        sidebar.onWorkspaceChange = { [weak self] in self?.pickWorkspace() }
        sidebar.onSettings = { [weak self] in self?.showSettings() }
        sidebar.onDeleteSession = { [weak self] in self?.deleteSession($0) }
        chat.onSend = { [weak self] text, attachments in self?.send(text, attachments: attachments) ?? false }
        chat.onStop = { [weak self] in self?.stop() }
        chat.onWorkspace = { [weak self] in self?.pickWorkspace() }
        chat.onBranch = { [weak self] id in self?.branch(at: id) }
        chat.onRewind = { [weak self] id in self?.rewind(to: id) }
        chat.onRegenerate = { [weak self] in self?.regenerate() }
        chat.onApproval = { [weak self] id, ok in
            self?.approvals.removeValue(forKey: id)?.resolve(ok)
        }
        chat.input.onProfileChange = { [weak self] profile in
            guard let self else { return }
            Settings.shared.agentProfile = profile
            NotificationCenter.default.post(name: .settingsChanged, object: nil)
            // An untouched session picks up the new persona immediately.
            if (self.live[self.session.id]?.messages ?? self.session.messages).isEmpty {
                self.updateActiveSession { $0.systemPromptInit(model: $0.model) }
            }
        }
        chat.input.onModelChange = { [weak self] model in
            guard let self else { return }
            Settings.shared.model = model
            self.updateActiveSession {
                $0.model = model
                if $0.messages.isEmpty { $0.systemPromptInit(model: model) }
            }
        }
        observers.append(NotificationCenter.default.addObserver(forName: .settingsChanged, object: nil, queue: .main) { [weak self] _ in
            guard let self else { return }
            MainActor.assumeIsolated {
                if ModelCatalog.shared.models.contains(Settings.shared.model) {
                    self.updateActiveSession {
                        $0.model = Settings.shared.model
                        if $0.messages.isEmpty { $0.systemPromptInit(model: Settings.shared.model) }
                    }
                }
                self.sidebar.reload()
                self.updateProfiles()
                self.updateModels()
                // Only a key/endpoint change needs a network refresh; an
                // autonomy or profile toggle must not clear the catalog.
                let key = Settings.shared.apiKey, base = Settings.shared.baseURL
                if key != self.lastCatalogKey || base != self.lastCatalogBase {
                    self.lastCatalogKey = key; self.lastCatalogBase = base
                    ModelCatalog.shared.refresh()
                }
            }
        })
        observers.append(NotificationCenter.default.addObserver(forName: .modelsChanged, object: nil, queue: .main) { [weak self] _ in
            self?.updateModels()
        })
        // The controller-managed split sizes panes to content width; the chat
        // pane declares the leftover itself (see ChatViewController). Its own
        // layout pass is not a reliable trigger — refit it on every split
        // resize and whenever the pane mix changes.
        splitView.postsFrameChangedNotifications = true
        observers.append(NotificationCenter.default.addObserver(forName: NSView.frameDidChangeNotification, object: splitView, queue: .main) { [weak self] _ in
            self?.chat.updateMetrics()
        })
        observers.append(NotificationCenter.default.addObserver(forName: NSSplitView.didResizeSubviewsNotification, object: splitView, queue: .main) { [weak self] _ in
            self?.chat.updateMetrics()
            self?.schedulePaneWidthSave()
        })
        observers.append(NotificationCenter.default.addObserver(forName: NSWindow.didResizeNotification, object: window, queue: .main) { [weak self] note in
            guard let self, let w = note.object as? NSWindow, w === self.window else { return }
            // Transient init-time layouts post resizes before the window is on
            // screen; swapping panes mid-layout strands a dead pane. Only react
            // to resizes once the window is visible.
            guard w.isVisible else { return }
            // Auto-collapse breakpoint: below ~1024px the sidebar hides,
            // leaving the permanent strip with its toggles.
            if (w.contentView?.bounds.width ?? 0) < 1024 {
                self.collapseSidebar()
            }
        })
        syncPaneToggles()
        Scheduler.shared.runTask = { [weak self] in self?.fireAutomation($0) }
        Scheduler.shared.onChange = { [weak self] in DispatchQueue.main.async { self?.sidebar.reload() } }
        updateProfiles()
        load(session)
        lastCatalogKey = Settings.shared.apiKey; lastCatalogBase = Settings.shared.baseURL
        ModelCatalog.shared.refresh()
        // Settle the window on the design size AFTER content loads: transient
        // fitting sizes price it wide during init, then hide and strand dead
        // space (window 1330, content 1125). Runs pre-show, so no flash.
        window.setContentSize(NSSize(width: 1240, height: 820))
        window.center()
        paneWidthsRestored = true
        // Teardown: resolve every pending approval (a wedged continuation
        // would hang its job forever) and flush pending session writes.
        observers.append(NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification, object: window, queue: .main) { [weak self] _ in
            self?.shutdown()
        })
    }
    required init?(coder: NSCoder) { fatalError() }
    deinit { observers.forEach(NotificationCenter.default.removeObserver) }

    /// Apply persisted pane widths once the window has a real layout. The
    /// init-time call runs before first layout (zero bounds) and is skipped,
    /// so without this the sidebar would start at an arbitrary width.
    override func showWindow(_ sender: Any?) {
        super.showWindow(sender)
        splitView.layoutSubtreeIfNeeded()
        applyPaneWidths()
        splitView.layoutSubtreeIfNeeded()
        chat.updateMetrics()
        // Default focus is the composer. Without this, AppKit's key-view
        // loop hands first responder to the first text field it finds —
        // the sidebar Search — and typing filters sessions instead of
        // composing a message.
        window?.initialFirstResponder = chat.input.textView
        window?.makeFirstResponder(chat.input.textView)
    }

    /// Window teardown path: deny all outstanding approvals, cancel running
    /// jobs, persist pending session writes.
    func shutdown() {
        guard !isShuttingDown else { return }
        isShuttingDown = true
        savePaneWidths()
        for (key, pending) in Array(approvals) {
            if session.id == pending.session { chat.dismissApproval(key: key) }
            approvals.removeValue(forKey: key)
            pending.resolve(false)
        }
        for (_, loop) in loops { loop.cancel() }
        for (_, job) in jobs { job.cancel() }
        for value in live.values { SessionStore.shared.touch(value) }
        SessionStore.shared.flush()
    }

    func showSettings() {
        if settingsWindow == nil { settingsWindow = SettingsWindowController() }
        settingsWindow?.showWindow(nil)
    }
    private func addInspector() {
        guard !inspectorAdded else { return }
        inspectorAdded = true
        if !splitView.arrangedSubviews.contains(inspector.view) {
            // Enter at zero width at the trailing edge, then grow. Decouple the
            // content first: pinned edge to edge, its required minimum widths
            // reach the split, which squeezes the lowest-priority pane (chat)
            // to nothing to honor them.
            inspectorSliding = true
            inspector.beginSlide(width: targetWidth(.inspector))
            splitView.addSubview(inspector.view)
            restackHoldingPriorities()
            // Layout BEFORE positioning: moving the new pane's divider in the
            // same pass as the insert left the chat squeezed to zero and the
            // split ignoring every later setPosition.
            splitView.layoutSubtreeIfNeeded()
            if let i = splitView.arrangedSubviews.firstIndex(of: inspector.view), i > 0 {
                splitView.setPosition(splitView.bounds.width - splitView.dividerThickness, ofDividerAt: i - 1)
                splitView.layoutSubtreeIfNeeded()
            }
        }
        inspector.load(session: session)
        syncPaneToggles()
        slide(.inspector, to: targetWidth(.inspector))
    }
    private func removeInspector() {
        guard inspectorAdded else { return }
        inspectorAdded = false
        syncPaneToggles()
        slide(.inspector, to: 0)
    }
    // MARK: pane toggles
    //
    // They live in the window's top row (a unified-compact toolbar), pinned
    // to the WINDOW's edges: sidebar toggle right after the traffic lights,
    // inspector toggle at the trailing edge. That row spans every pane, so
    // opening or closing a pane can never move them. In the chat header they
    // slid by a full pane width on every toggle.
    private lazy var sidebarToggle = paneToggle("sidebar.left", "Sidebar", "⌥⌘S") { [weak self] in self?.toggleSidebar() }
    /// The inspector has no generic toggle: its four tabs are direct buttons
    /// at the trailing edge (Claude-style). Click one to open on it, another
    /// to switch, the active one to close.
    private lazy var inspectorTabs: NSStackView = {
        let stack = NSStackView(views: inspector.tabButtons)
        stack.orientation = .horizontal; stack.alignment = .centerY; stack.spacing = 2
        inspector.onTabPress = { [weak self] i in self?.inspectorTabPressed(i) }
        return stack
    }()
    private func inspectorTabPressed(_ i: Int) {
        if inspectorAdded && inspector.selectedTab == i { removeInspector(); return }
        addInspector()
        inspector.selectTab(i)
        syncPaneToggles()
    }

    private func paneToggle(_ symbol: String, _ name: String, _ shortcut: String,
                            _ action: @escaping () -> Void) -> ActionButton {
        let b = ActionButton(symbol: symbol, style: .icon, action: action)
        b.setFixedSize(28)
        b.iconBox = 18 // top-row scale, matches the inspector buttons
        // Bare glyph in quiet ink, like Finder's sidebar button: no resting
        // box. Hover still brings the wash, so it reads as a control on approach.
        b.tint = T.labelTertiary
        b.actsOnFirstClick = true // titlebar controls work on an inactive window
        b.toolTip = "Show or hide the \(name.lowercased()) (\(shortcut))"
        b.setAccessibilityLabel(name)
        return b
    }

    private static let sidebarToggleID = NSToolbarItem.Identifier("dsh.toggleSidebar")
    private static let inspectorTabsID = NSToolbarItem.Identifier("dsh.inspectorTabs")

    /// The window's single top row is a unified-compact toolbar: macOS sizes
    /// it and centers the traffic lights in it, so lights, toggles and the
    /// chat header's breadcrumbs share one centerline with nothing above.
    /// Sidebar toggle right after the lights, inspector toggle at the trailing
    /// edge: both pinned to the window, never moved by the panes.
    private func installTopRow(in window: NSWindow) {
        let toolbar = NSToolbar(identifier: "dsh.main")
        toolbar.delegate = self
        toolbar.displayMode = .iconOnly
        toolbar.allowsUserCustomization = false
        toolbar.showsBaselineSeparator = false
        window.toolbar = toolbar
        window.toolbarStyle = .unifiedCompact
    }

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [Self.sidebarToggleID, .flexibleSpace, Self.inspectorTabsID]
    }
    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        toolbarDefaultItemIdentifiers(toolbar)
    }
    func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier id: NSToolbarItem.Identifier,
                 willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        let item = NSToolbarItem(itemIdentifier: id)
        if id == Self.inspectorTabsID {
            item.view = inspectorTabs
            item.label = "Inspector"
            return item
        }
        let button = sidebarToggle
        // The toolbar stretches an item's view to the row height; host the
        // 28pt button so its hover wash stays square and centered on the row.
        let host = NSView()
        host.addSubview(button)
        button.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            button.centerXAnchor.constraint(equalTo: host.centerXAnchor),
            button.centerYAnchor.constraint(equalTo: host.centerYAnchor),
            host.widthAnchor.constraint(equalToConstant: 28),
        ])
        item.view = host
        item.label = "Sidebar"
        item.toolTip = button.toolTip
        return item
    }

    /// Pane state is spoken (accessibility value), not boxed: a resting
    /// selected wash made the corners the heaviest marks in the window.
    private func syncPaneToggles() {
        sidebarToggle.setAccessibilityValue(sidebarShown ? "shown" : "hidden")
        inspector.setTabsActive(inspectorAdded)
        // Layout settles first: the insets read the toggles' laid-out frames.
        // Not mid-slide: the slide sets them every frame from the divider it
        // is about to apply, and a late async pass would use stale geometry.
        DispatchQueue.main.async { [weak self] in
            guard let self, !self.paneSliding else { return }
            self.updateTitlebarMetrics()
        }
    }

    /// The chat header is the titlebar row. Give it the real titlebar height,
    /// and while a pane is closed (the chat column then reaches that window
    /// edge) inset the breadcrumbs past the edge toggle so they never collide.
    /// `chatMinX` (window coordinates): pass the chat pane's left edge for the
    /// frame being applied, during a slide. Reading chat.view's frame there
    /// lags the divider by one layout pass, so the breadcrumbs trailed it.
    private func updateTitlebarMetrics(chatMinX: CGFloat? = nil, chatMaxX: CGFloat? = nil) {
        guard let window else { return }
        let height = max(28, window.frame.height - window.contentLayoutRect.height)
        var chatFrame = chat.view.convert(chat.view.bounds, to: nil)
        if let chatMinX {
            chatFrame.size.width = chatFrame.maxX - chatMinX
            chatFrame.origin.x = chatMinX
        }
        if let chatMaxX { chatFrame.size.width = chatMaxX - chatFrame.minX }
        let left = sidebarToggle.convert(sidebarToggle.bounds, to: nil)
        let right = inspectorTabs.convert(inspectorTabs.bounds, to: nil)
        let leading = max(20, left.maxX + 14 - chatFrame.minX)
        let trailing = max(16, chatFrame.maxX - (right.minX - 10))
        chat.setTitlebarMetrics(height: height, leading: leading, trailing: trailing)
        sidebar.setTopInset(height)
        inspector.setTopInset(height)
    }
    /// Responder-chain target for a transcript row's Review button.
    @objc func showReview(_ sender: Any?) {
        addInspector()
        inspector.showReview(path: (sender as? ReviewRequest)?.path)
    }
    /// Settle the split synchronously, THEN re-derive the chat width from
    /// settled geometry. updateMetrics reads live sibling widths; if it runs
    /// on a mid-transition frame it bakes a transient width into the chat
    /// constraint and the sidebar can never take the space back (ratchet).
    private func settlePanes() {
        splitView.layoutSubtreeIfNeeded()
        applyPaneWidths()
        splitView.layoutSubtreeIfNeeded()
        chat.updateMetrics()
    }
    private func applyPaneWidths() {
        guard splitView.bounds.width > 0 else { return }
        // Divider 0 trails the sidebar pane.
        // A pane mid-slide owns its divider: settling the other pane's
        // finish must not snap it to its saved width.
        if sidebarShown, !sidebarSliding, let i = splitView.arrangedSubviews.firstIndex(of: sidebar.view) {
            splitView.setPosition(Settings.shared.sidebarWidth, ofDividerAt: i)
        }
        let panes = splitView.arrangedSubviews
        if inspectorAdded, !inspectorSliding, let j = panes.firstIndex(of: inspector.view), j > 0 {
            let position = splitView.bounds.width
                - Settings.shared.inspectorWidth
                - splitView.dividerThickness
            splitView.setPosition(position, ofDividerAt: j - 1)
        }
    }
    // MARK: - NSSplitViewDelegate: explicit min/max per pane.

    private func minWidth(of view: NSView) -> CGFloat {
        if view === sidebar.view { return sidebarSliding ? 0 : Settings.sidebarWidthRange.lowerBound }
        if view === inspector.view { return inspectorSliding ? 0 : Settings.inspectorWidthRange.lowerBound }
        return 480 // chat
    }
    private func maxWidth(of view: NSView) -> CGFloat {
        if view === sidebar.view { return Settings.sidebarWidthRange.upperBound }
        if view === inspector.view { return Settings.inspectorWidthRange.upperBound }
        return .greatestFiniteMagnitude // chat
    }
    /// The center pane absorbs window resizes; every other pane holds.
    private func restackHoldingPriorities() {
        for (i, v) in splitView.arrangedSubviews.enumerated() {
            splitView.setHoldingPriority(v === chat.view ? .init(1) : .defaultHigh, forSubviewAt: i)
        }
    }
    /// Divider floor: left panes keep their minimums, and right panes keep
    /// theirs.
    func splitView(_ splitView: NSSplitView, constrainMinCoordinate proposed: CGFloat, ofSubviewAt divider: Int) -> CGFloat {
        let panes = splitView.arrangedSubviews
        var lo = proposed
        var x: CGFloat = 0
        for (i, v) in panes.enumerated() where i <= divider {
            if i > 0 { x += splitView.dividerThickness }
            x += minWidth(of: v)
        }
        lo = max(lo, x)
        var y = splitView.bounds.width
        for v in panes.dropFirst(divider + 1) {
            y -= maxWidth(of: v) + splitView.dividerThickness
        }
        return max(lo, y)
    }
    /// Divider ceiling: right panes keep their minimums, and left panes keep
    /// theirs.
    func splitView(_ splitView: NSSplitView, constrainMaxCoordinate proposed: CGFloat, ofSubviewAt divider: Int) -> CGFloat {
        let panes = splitView.arrangedSubviews
        var hi = proposed
        var x = splitView.bounds.width
        for v in panes.dropFirst(divider + 1) {
            x -= minWidth(of: v) + splitView.dividerThickness
        }
        hi = min(hi, x)
        var y: CGFloat = 0
        for (i, v) in panes.enumerated() where i <= divider {
            if i > 0 { y += splitView.dividerThickness }
            y += maxWidth(of: v)
        }
        return min(hi, y)
    }
    func splitView(_ splitView: NSSplitView, canCollapseSubview subview: NSView) -> Bool {
        // Not mid-slide: a slide passes through zero width on purpose, and a
        // collapsible pane at zero is hidden and its divider stops tracking
        // positions (the chat was squeezed to nothing on entry).
        subview === inspector.view && !inspectorSliding
    }
    /// Diagnostic mode (`--probe-divider-drag`): skip persistence so a
    /// self-test drag never pollutes saved pane widths.
    var probeNoSave = false
    private func schedulePaneWidthSave() {
        // Mid-slide widths are animation frames, not a user's chosen width.
        guard paneWidthsRestored, !probeNoSave, !paneSliding else { return }
        paneWidthSaveWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.savePaneWidths() }
        paneWidthSaveWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2, execute: work)
    }
    private func savePaneWidths() {
        guard paneWidthsRestored, !paneSliding else { return }
        if sidebarShown, sidebar.isViewLoaded {
            Settings.shared.sidebarWidth = sidebar.view.frame.width
        }
        if inspectorAdded, inspector.isViewLoaded {
            Settings.shared.inspectorWidth = inspector.view.frame.width
        }
    }
    func toggleInspector() {
        inspectorAdded ? removeInspector() : addInspector()
    }
    /// Sidebar show/hide. The whole pane leaves the split when collapsed;
    /// reopen it from the chat header toggle or View > Toggle Sidebar.
    func toggleSidebar() {
        sidebarShown ? collapseSidebar() : expandSidebar()
    }
    private var sidebarShown = true
    func collapseSidebar() {
        guard sidebarShown else { return }
        sidebarShown = false
        syncPaneToggles()
        slide(.sidebar, to: 0)
    }
    func expandSidebar() {
        guard !sidebarShown else { return }
        sidebarShown = true
        if !splitView.arrangedSubviews.contains(sidebar.view) {
            // Enter at zero width, then grow: never a full-width first frame.
            // Content decoupled first (see addInspector).
            sidebarSliding = true
            sidebar.beginSlide(width: targetWidth(.sidebar))
            splitView.insertArrangedSubview(sidebar.view, at: 0)
            restackHoldingPriorities()
            splitView.layoutSubtreeIfNeeded() // layout before positioning (see addInspector)
            splitView.setPosition(0, ofDividerAt: 0)
            splitView.layoutSubtreeIfNeeded() // first frame: pane present at 0, chat unmoved
        }
        syncPaneToggles()
        slide(.sidebar, to: targetWidth(.sidebar))
    }

    // MARK: pane slide
    //
    // Inserting or removing a pane in one step made the chat jump a full pane
    // width in a single frame, then re-wrap, then move its breadcrumbs a frame
    // later: a pop plus a correction, read as flicker. Instead the divider
    // glides; the pane's content holds its full width and is clipped (each
    // pane's beginSlide), the chat column and breadcrumbs follow every frame,
    // and a pane leaves the split only once it reaches zero. A toggle during a
    // slide reverses from wherever it is.
    private enum Pane { case sidebar, inspector }
    private var sidebarSliding = false
    private var inspectorSliding = false
    private var paneSliding: Bool { sidebarSliding || inspectorSliding }
    private var slideTimers: [Pane: Timer] = [:]
    private static let slideDuration: CFTimeInterval = 0.18

    private func paneView(_ pane: Pane) -> NSView { pane == .sidebar ? sidebar.view : inspector.view }
    private func setSliding(_ pane: Pane, _ on: Bool) {
        if pane == .sidebar { sidebarSliding = on } else { inspectorSliding = on }
    }
    private func paneShown(_ pane: Pane) -> Bool { pane == .sidebar ? sidebarShown : inspectorAdded }
    private func targetWidth(_ pane: Pane) -> CGFloat {
        let range = pane == .sidebar ? Settings.sidebarWidthRange : Settings.inspectorWidthRange
        let saved = pane == .sidebar ? Settings.shared.sidebarWidth : Settings.shared.inspectorWidth
        return min(range.upperBound, max(range.lowerBound, saved))
    }
    /// Divider index and position that give `pane` the width `w`.
    private func divider(for pane: Pane, width w: CGFloat) -> (index: Int, position: CGFloat)? {
        guard let i = splitView.arrangedSubviews.firstIndex(of: paneView(pane)) else { return nil }
        if pane == .sidebar { return (i, w) }
        guard i > 0 else { return nil }
        return (i - 1, splitView.bounds.width - w - splitView.dividerThickness)
    }

    private func slide(_ pane: Pane, to target: CGFloat) {
        slideTimers[pane]?.invalidate(); slideTimers[pane] = nil
        let view = paneView(pane)
        let start = splitView.arrangedSubviews.contains(view) ? view.frame.width : 0
        let finish = { [weak self] in
            guard let self else { return }
            self.slideTimers[pane] = nil
            self.setSliding(pane, false)
            if pane == .sidebar { self.sidebar.endSlide() } else { self.inspector.endSlide() }
            if !self.paneShown(pane), self.splitView.arrangedSubviews.contains(view) {
                self.splitView.removeArrangedSubview(view)
                view.removeFromSuperview()
                self.restackHoldingPriorities()
            }
            self.settlePanes()
            self.updateTitlebarMetrics()
        }
        let animate = !Settings.isTestRun
            && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
            && window?.isVisible == true
            && abs(target - start) > 1
        guard animate else { finish(); return }

        setSliding(pane, true)
        let full = targetWidth(pane)
        if pane == .sidebar { sidebar.beginSlide(width: full) } else { inspector.beginSlide(width: full) }
        let began = CACurrentMediaTime()
        let timer = Timer(timeInterval: 1.0 / 120, repeats: true) { [weak self] timer in
            guard let self, let (index, _) = self.divider(for: pane, width: 0) else { timer.invalidate(); return }
            // Time-based, not frame-counted: a dropped frame never slows it.
            let p = min(1, (CACurrentMediaTime() - began) / Self.slideDuration)
            let eased = 1 - pow(1 - p, 4) // ease-out quart, no overshoot
            let width = start + (target - start) * eased
            guard let (_, position) = self.divider(for: pane, width: width) else { return }
            self.splitView.setPosition(position, ofDividerAt: index)
            // Breadcrumbs for THIS frame: the chat edge sits one divider past
            // the position just applied (reading chat.view lags a layout pass).
            let splitMinX = self.splitView.convert(self.splitView.bounds, to: nil).minX
            if pane == .sidebar {
                self.updateTitlebarMetrics(chatMinX: splitMinX + position + self.splitView.dividerThickness)
            } else {
                self.updateTitlebarMetrics(chatMaxX: splitMinX + position)
            }
            // Apply the pane frames and the breadcrumb inset in ONE layout
            // pass, now, so no observer (or frame) ever sees one without the other.
            self.splitView.layoutSubtreeIfNeeded()
            if p >= 1 { timer.invalidate(); finish() }
        }
        RunLoop.main.add(timer, forMode: .common) // keeps running during tracking
        slideTimers[pane] = timer
    }
    func newSession() {
        // Always a fresh blank, every time ⌘N is pressed. The blank is
        // memory-only: an unused one is discarded by the next ⌘N or by
        // switching away, and persistIfDraft saves it on first activity.
        var blank = Session(title: "New session", workspace: Settings.shared.workspace, model: Settings.shared.model)
        blank.systemPromptInit()
        draft = blank
        load(blank)
        window?.makeFirstResponder(chat.input.textView)
    }

    /// Save a memory-only draft when it first sees activity (a run starts).
    /// Persisted sessions and automation sessions are already tracked.
    func persistIfDraft(_ value: Session) {
        guard draft?.id == value.id else { return }
        SessionStore.shared.adopt(value)
        draft = nil
    }

    /// Delete the currently shown session (File > Delete Session / ⌘⌫).
    func deleteSelectedSession() {
        deleteSession(session.id)
    }
    private func deleteSession(_ id: UUID) {
        // Deleting a session that is still running would strand its job (the
        // loop would keep writing to a session the store no longer tracks), so
        // refuse — but say so instead of silently ignoring the click.
        guard jobs[id] == nil else {
            let busy = NSAlert()
            busy.messageText = "This conversation is still running."
            busy.informativeText = "Stop it first, then delete it."
            busy.addButton(withTitle: "OK")
            busy.runModal()
            return
        }
        let alert = NSAlert()
        alert.messageText = "Delete this conversation?"
        alert.informativeText = "This removes the saved conversation, not any workspace files."
        alert.addButton(withTitle: "Delete"); alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let wasActive = activeSessionID == id
        SessionStore.shared.delete(id)
        chat.dropDraft(id)
        if wasActive { newSession() } else { sidebar.reload() }
    }
    /// Review badge from the session's changed files, open inspector or not.
    private func updateReviewCount(_ changes: [FileChange]) {
        inspector.setReviewCount(Set(changes.map(\.path)).count)
    }

    private func load(_ value: Session) {
        activeSessionID = value.id
        chat.load(session: value)
        // The inspector's four panes are expensive to build; only refresh
        // them when the pane is actually in the split. addInspector()
        // loads the current session when the pane is attached.
        if inspectorAdded { inspector.load(session: value) }
        updateReviewCount(value.changes)
        sidebar.selectedSession = value.id; sidebar.reload()
        updateModels()
        // Re-surface approvals that arrived while this session was in the background.
        for (key, pending) in approvals where pending.session == value.id {
            chat.showApproval(name: pending.name, summary: pending.summary, key: key)
        }
    }
    private func updateProfiles() {
        chat.input.setProfiles(AgentProfiles.all.map { $0.id },
                               preferred: Settings.shared.agentProfile)
    }
    private func updateModels() {
        switch ModelCatalog.shared.state {
        case .disconnected: chat.input.showModelStatus("Connect DeepSeek")
        case .loading: chat.input.showModelStatus("Loading models...")
        case .ready:
            chat.input.setModels(ModelCatalog.shared.models,
                                 preferred: ModelCatalog.preferredModel(models: ModelCatalog.shared.models,
                                                                        settingsDefault: Settings.shared.model,
                                                                        sessionModel: session.model))
        case .failed(let error):
            chat.input.showModelStatus("Models unavailable")
            chat.status(error + "  Open Settings to retry.")
        }
    }
    private func pickWorkspace() {
        guard jobs[session.id] == nil else { return }
        let panel = NSOpenPanel(); panel.canChooseDirectories = true; panel.canChooseFiles = false
        panel.prompt = "Use workspace"
        if panel.runModal() == .OK, let url = panel.url {
            Settings.shared.workspace = url.path
            // Route through updateActiveSession: for a memory-only draft it
            // writes back to `draft`, so the next send() runs in the new
            // workspace instead of the stale one the UI no longer shows.
            updateActiveSession {
                $0.workspace = url.path
                var prompt = $0; prompt.systemPromptInit(model: $0.model)
                if $0.wire.first?.role == .system, let p = prompt.wire.first {
                    $0.wire[0] = p
                } else if let p = prompt.wire.first {
                    $0.wire.insert(p, at: 0)
                }
            }
            load(session)
        }
    }
    private func stop() {
        let id = session.id
        loops[id]?.cancel(); jobs[id]?.cancel()
        if loops[id] == nil { jobs.removeValue(forKey: id) }
        let pending = approvals.filter { $0.value.session == id }
        for (key, value) in pending {
            approvals.removeValue(forKey: key)
            chat.dismissApproval(key: key)
            value.resolve(false)
        }
        chat.setRunning(false)
        chat.status("Stopping...")
    }
    private func send(_ text: String, attachments: [Attachment]) -> Bool {
        guard jobs[session.id] == nil,
              !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !attachments.isEmpty,
              let model = chat.input.selectedModel, ModelCatalog.shared.models.contains(model) else { return false }
        updateActiveSession { $0.model = model }
        let value = live[session.id] ?? session
        var prompt = text
        if text.hasPrefix("/") {
            let parts = text.dropFirst().split(separator: " ", maxSplits: 1)
            if let command = parts.first, let expanded = PluginEngine.shared.expandCommand(String(command), args: parts.count > 1 ? String(parts[1]) : "") {
                prompt = expanded
            }
        }
        let attached = attachments
        let pathContext = ToolContext(workspace: value.workspace)
        var fileURLs: [URL] = []
        for token in text.split(whereSeparator: \.isWhitespace) where token.hasPrefix("@") {
            // Confine to the workspace: @../../etc/passwd must not escape.
            let raw = String(token.dropFirst())
            if raw.hasPrefix("/") || raw.hasPrefix("~") { continue }
            guard let resolved = try? pathContext.resolveChecked(raw) else { continue }
            let path = URL(fileURLWithPath: resolved)
            // Stat before extracting: only regular files, capped size, no
            // multi-GB synchronous read during send.
            guard let attrs = try? FileManager.default.attributesOfItem(atPath: path.path),
                  let type = attrs[.type] as? FileAttributeType, type == .typeRegular,
                  let size = attrs[.size] as? Int, size <= 50_000_000 else { continue }
            fileURLs.append(path)
        }
        if fileURLs.isEmpty {
            start(value, prompt: prompt, attachments: attached, interactive: true)
        } else {
            let id = value.id
            chat.setRunning(true)
            jobs[id] = Task { [weak self] in
                let extracted = await Extract.attachments(for: fileURLs)
                guard !Task.isCancelled else { return }
                await MainActor.run {
                    guard let self, self.jobs[id] != nil else { return }
                    self.jobs.removeValue(forKey: id)
                    if let current = self.live[id] ?? SessionStore.shared.sessions.first(where: { $0.id == id }) {
                        self.start(current, prompt: prompt, attachments: attached + extracted, interactive: true)
                    } else {
                        self.chat.setRunning(false)
                    }
                }
            }
        }
        return true
    }
    private func start(_ value: Session, prompt: String, attachments: [Attachment], interactive: Bool,
                       wireContent: String? = nil) {
        let id = value.id
        var current = value; current.running = true
        persistIfDraft(current)
        live[id] = current; SessionStore.shared.touch(current)
        if activeSessionID == id { chat.setRunning(true) }
        let loop = AgentLoop()
        loop.client.config = .init(baseURL: Settings.shared.baseURL, apiKey: Settings.shared.apiKey, model: value.model)
        loop.onEvent = { [weak self] event in DispatchQueue.main.async { self?.handle(event, sessionID: id) } }
        // Unattended runs never exceed auto-approved reads + writes, whatever
        // the global setting is when they fire. Shell, plugin, and schedule
        // tools need approval at that level, and approval here always denies.
        if !interactive { loop.autonomyCap = .autoWrite }
        loop.approve = { [weak self] name, summary in
            guard interactive else { return false }
            return await withCheckedContinuation { continuation in
                DispatchQueue.main.async {
                    guard let self, !self.isShuttingDown else { continuation.resume(returning: false); return }
                    // Queue, never auto-deny: approvals for background sessions
                    // are re-shown when the user switches back (see load()).
                    let key = UUID()
                    self.approvals[key] = PendingApproval(session: id, name: name, summary: summary,
                                                          resolve: { continuation.resume(returning: $0) })
                    if self.session.id == id {
                        self.chat.showApproval(name: name, summary: summary, key: key)
                    }
                }
            }
        }
        loops[id] = loop
        jobs[id] = Task { [weak self] in
            let result = await loop.run(session: current, userText: prompt, attachments: attachments,
                                        wireContent: wireContent)
            await MainActor.run {
                guard let self else { return }
                var result = result; result.running = false
                // A model picked mid-run (updateActiveSession) must survive
                // the loop's older snapshot persisting the session here.
                if let liveValue = self.live[id] { result.model = liveValue.model }
                self.live.removeValue(forKey: id); self.jobs.removeValue(forKey: id); self.loops.removeValue(forKey: id)
                SessionStore.shared.touch(result)
                if self.isShuttingDown { SessionStore.shared.flush() }
                if self.activeSessionID == id {
                    self.chat.setRunning(false)
                    if self.inspectorAdded { self.inspector.load(session: result) }
                }
                self.sidebar.reload()
                if let task = result.scheduledTaskID {
                    Scheduler.shared.recordResult(taskID: task, sessionID: id, error: self.runErrors[id])
                }
                self.runErrors.removeValue(forKey: id)
            }
        }
    }
    private func handle(_ event: AgentEvent, sessionID id: UUID) {
        let visible = session.id == id
        switch event {
        case .user(let message):
            live[id]?.messages.append(message)
            if live[id]?.title == "New session" { live[id]?.title = String(message.content.prefix(60)) }
            if visible { chat.append(message); if inspectorAdded, let s = live[id] { inspector.refreshLive(session: s) } }
        case .assistantStart(let mid):
            var message = Message(role: .assistant); message.id = mid
            live[id]?.messages.append(message)
            if visible { chat.assistantStart(mid); if inspectorAdded, let s = live[id] { inspector.refreshLive(session: s) } }
        case .text(let mid, let delta):
            if let i = live[id]?.messages.firstIndex(where: { $0.id == mid }) { live[id]?.messages[i].content += delta }
            if visible { chat.appendText(mid, delta) }
        case .reasoning(let mid, let delta):
            if let i = live[id]?.messages.firstIndex(where: { $0.id == mid }) { live[id]?.messages[i].reasoning += delta }
            if visible { chat.appendReasoning(mid, delta) }
        case .discardAssistant(let mid):
            live[id]?.messages.removeAll { $0.id == mid }
            if visible { chat.removeMessage(mid) }
        case .stepStart(let mid, let step):
            if let i = live[id]?.messages.firstIndex(where: { $0.id == mid }) { live[id]?.messages[i].steps.append(step) }
            if visible { chat.stepStart(mid, step) }
        case .stepFinish(let mid, let step):
            if let i = live[id]?.messages.firstIndex(where: { $0.id == mid }),
               let j = live[id]?.messages[i].steps.firstIndex(where: { $0.id == step.id }) { live[id]?.messages[i].steps[j] = step }
            if visible { chat.stepFinish(mid, step); if inspectorAdded, let s = live[id] { inspector.refreshLive(session: s) } }
        case .change(let change):
            live[id]?.changes.append(change)
            if visible, inspectorAdded { inspector.addChange(change) }
            if visible { updateReviewCount(live[id]?.changes ?? []) }
        case .status(let text): if visible { chat.status(text) }
        case .failed(let error):
            if runErrors[id] == nil { runErrors[id] = error }
            if visible { chat.status(error, isError: true) }
        case .done: break
        }
        if case .user = event, let s = live[id] { SessionStore.shared.touch(s); sidebar.reload() }
    }
    private func fireAutomation(_ task: AutomationTask) -> UUID? {
        guard case .ready = ModelCatalog.shared.state else { return nil }
        var value = SessionStore.shared.newSession(workspace: task.workspace)
        value.title = task.title
        value.model = ModelCatalog.preferredModel(models: ModelCatalog.shared.models,
                                                  settingsDefault: Settings.shared.model,
                                                  sessionModel: value.model)
        value.systemPromptInit(model: value.model)
        value.scheduledTaskID = task.id
        start(value, prompt: task.prompt, attachments: [], interactive: false)
        return value.id
    }

    private func updateActiveSession(_ update: (inout Session) -> Void) {
        let id = activeSessionID
        var value = live[id] ?? session
        update(&value)
        if live[id] != nil { live[id] = value }
        else if draft?.id == id { draft = value }
        SessionStore.shared.touch(value)
    }
}

// MARK: - Turn actions: Branch, Rewind, Regenerate

extension MainWindowController {
    /// New independent session holding the conversation through the turn that
    /// ends at `messageID` (same workspace; files untouched), then open it.
    fileprivate func branch(at messageID: UUID) {
        let source = session
        guard jobs[source.id] == nil, let turn = SessionEditing.turn(of: messageID, in: source) else { return }
        guard let copy = SessionEditing.branch(source, throughTurn: turn) else {
            chat.status("This conversation's history is inconsistent; it can't be branched safely.", isError: true)
            return
        }
        SessionStore.shared.adopt(copy)
        load(copy)
        chat.input.focusEditor()
    }

    /// Cut the conversation after the turn that ends at `messageID` and put
    /// back the files the agent changed later.
    fileprivate func rewind(to messageID: UUID) {
        let source = session
        guard jobs[source.id] == nil, let turn = SessionEditing.turn(of: messageID, in: source) else { return }
        rewind(source, keepingTurns: turn, regenerating: false) { _ in }
    }

    /// Replace the latest response: rewind to just before the last user
    /// message (restoring the files that response changed), then send that
    /// message again exactly as the model saw it, attachments included.
    fileprivate func regenerate() {
        let source = session
        let starts = SessionEditing.turnStarts(source)
        guard jobs[source.id] == nil, let last = starts.last else { return }
        let visible = source.messages[last].content
        let sent = source.wire.last(where: { $0.role == .user })?.content
        rewind(source, keepingTurns: starts.count - 2, regenerating: true) { [weak self] rewound in
            self?.start(rewound, prompt: visible, attachments: [], interactive: true, wireContent: sent)
        }
    }

    private func rewind(_ source: Session, keepingTurns k: Int, regenerating: Bool,
                        then: @escaping (Session) -> Void) {
        guard let (kept, dropped) = SessionEditing.truncated(source, keepingTurns: k) else {
            chat.status("This conversation's history is inconsistent; it can't be rewound safely.", isError: true)
            return
        }
        let plan = SessionEditing.restorePlan(for: dropped, read: SessionEditing.readText)
        let commit = { [weak self] in
            guard let self else { return }
            let failures = SessionEditing.apply(plan)
            SessionStore.shared.touch(kept)
            if self.live[kept.id] != nil { self.live[kept.id] = kept }
            self.load(kept)
            self.chat.input.focusEditor()
            if !failures.isEmpty {
                self.chat.status("Couldn't restore \(failures.joined(separator: "; "))", isError: true)
            }
            then(kept)
        }
        // Regenerating a response that touched no files: nothing to confirm.
        if regenerating && plan.isEmpty { commit(); return }

        let later = SessionEditing.turnCount(source) - (k + 1)
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = regenerating ? "Regenerate the last response?" : "Rewind to here?"
        alert.informativeText = Self.rewindSummary(plan: plan, laterTurns: later, regenerating: regenerating)
        alert.addButton(withTitle: regenerating ? "Regenerate" : "Rewind")
        alert.addButton(withTitle: "Cancel")
        guard let window else { return }
        alert.beginSheetModal(for: window) { response in
            if response == .alertFirstButtonReturn { commit() }
        }
    }

    /// Plain-language account of exactly what a rewind will and won't do.
    static func rewindSummary(plan: SessionEditing.RestorePlan, laterTurns: Int, regenerating: Bool) -> String {
        func names(_ paths: [String]) -> String {
            let n = paths.map { ($0 as NSString).lastPathComponent }
            return n.count <= 4 ? n.joined(separator: ", ") : n.prefix(4).joined(separator: ", ") + " and \(n.count - 4) more"
        }
        func files(_ n: Int) -> String { n == 1 ? "1 file" : "\(n) files" }
        var lines: [String] = []
        lines.append(regenerating
            ? "The last response is replaced with a new one."
            : "The \(laterTurns == 1 ? "later turn is" : "\(laterTurns) later turns are") removed from this conversation.")
        if !plan.restores.isEmpty {
            lines.append("Restores \(files(plan.restores.count)) the agent changed: \(names(plan.restores.map(\.path))).")
        }
        if !plan.conflicts.isEmpty {
            let one = plan.conflicts.count == 1
            lines.append("Leaves \(files(plan.conflicts.count)) as \(one ? "it is" : "they are") because \(one ? "it" : "they") changed since: \(names(plan.conflicts)).")
        }
        if !plan.unrestorable.isEmpty {
            lines.append("Can't restore \(files(plan.unrestorable.count)) (the original wasn't text): \(names(plan.unrestorable)).")
        }
        lines.append("Commands the agent ran aren't undone.")
        return lines.joined(separator: "\n\n")
    }
}
