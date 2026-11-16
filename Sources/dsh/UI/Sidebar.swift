import AppKit

enum SidebarSelection { case session(UUID) }

/// Official-style sidebar: fish + wordmark logo row, New Session CTA, panel rows,
/// Sessions section with search, bottom-pinned settings. Toggles all the way
/// away; reopen from the View menu.
final class SidebarViewController: NSViewController {
    var onSelect: (SidebarSelection) -> Void = { _ in }
    var onNewSession: () -> Void = {}
    var onWorkspaceChange: () -> Void = {}
    var onDeleteSession: (UUID) -> Void = { _ in }
    var onSettings: () -> Void = {}
    var selectedSession: UUID?
    private let list = NSStackView()
    private var search: NSSearchField!
    private var panel: NSPanel?
    private var filter = ""
    private var accountRow: ActionButton?
    private var searchWrap: TintedView!

    override func loadView() {
        let root = TintedView(T.sidebarFill)
        let edge = TintedView(T.borderL1)
        edge.widthAnchor.constraint(equalToConstant: 0.5).isActive = true
        root.addSubview(edge)
        edge.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            edge.topAnchor.constraint(equalTo: root.topAnchor),
            edge.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            edge.trailingAnchor.constraint(equalTo: root.trailingAnchor),
        ])

        // MARK: wordmark — stacked two-line lockup beside the fish.
        let fish = BrandMarkView.fish(width: 22)
        let deepseek = T.label("DeepSeek", T.ui(16, .semibold), T.labelPrimary)
        deepseek.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        deepseek.lineBreakMode = .byTruncatingTail
        let harnessLabel = T.label("Harness", T.ui(11.5, .medium), T.labelSecondary)
        let kerned = NSMutableAttributedString(string: "Harness")
        kerned.addAttribute(.kern, value: 0.6, range: NSRange(location: 0, length: kerned.length))
        harnessLabel.attributedStringValue = kerned
        let titleCol = vertical([deepseek, harnessLabel], spacing: 1)
        titleCol.alignment = .leading
        let lockup = horizontal([fish, titleCol], spacing: 8)
        lockup.alignment = .centerY
        lockup.toolTip = "DeepSeek Harness (Preview)"
        let logoRow = horizontal([lockup, NSView()], spacing: 8)
        logoRow.edgeInsets = NSEdgeInsets(top: 0, left: 12, bottom: 0, right: 8)
        logoRow.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(logoRow)

        // MARK: primary actions.
        // A nav row, not a filled capsule: it is a ⌘N action, and the blue
        // fill made it the loudest thing on screen. The glyph carries the accent.
        let new = ActionButton("New session", symbol: "square.and.pencil", style: .nav) { [weak self] in self?.onNewSession() }
        new.tint = T.labelPrimary; new.iconTint = T.accent
        new.caption = "⌘N"
        new.setAccessibilityLabel("New session")

        let plugins = ActionButton("Plugins", symbol: "puzzlepiece.extension", style: .nav) { [weak self] in self?.showPlugins() }
        plugins.tint = T.labelSecondary
        let automations = ActionButton("Automations", symbol: "clock.arrow.circlepath", style: .nav) { [weak self] in self?.showAutomations() }
        automations.tint = T.labelSecondary
        let nav = vertical([new, plugins, automations], spacing: 2)
        nav.stretchRows()

        // MARK: sessions section.
        let sectionLabel = T.label("Sessions", T.ui(13, .medium), T.labelTertiary)
        let sectionWrap = horizontal([sectionLabel], spacing: 0)
        sectionWrap.edgeInsets = NSEdgeInsets(top: 0, left: 12, bottom: 0, right: 0)
        searchWrap = TintedView(T.selector, radius: 8)
        searchWrap.heightAnchor.constraint(equalToConstant: 30).isActive = true
        search = NSSearchField()
        search.placeholderString = "Search"
        search.setAccessibilityLabel("Search sessions")
        search.font = T.ui(13); search.focusRingType = .none
        search.target = self; search.action = #selector(searchChanged)
        search.delegate = self
        search.sendsSearchStringImmediately = true
        search.isBordered = false; search.drawsBackground = false
        search.backgroundColor = .clear
        if let cell = search.cell as? NSSearchFieldCell {
            cell.searchButtonCell = nil
        }
        let mag = T.icon("magnifyingglass", size: 13, color: T.labelTertiary)
        mag.widthAnchor.constraint(equalToConstant: 16).isActive = true
        mag.heightAnchor.constraint(equalToConstant: 16).isActive = true
        searchWrap.addSubview(mag)
        searchWrap.addSubview(search)
        mag.translatesAutoresizingMaskIntoConstraints = false
        search.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            mag.leadingAnchor.constraint(equalTo: searchWrap.leadingAnchor, constant: 8),
            mag.centerYAnchor.constraint(equalTo: searchWrap.centerYAnchor),
            search.leadingAnchor.constraint(equalTo: mag.trailingAnchor, constant: 4),
            search.trailingAnchor.constraint(equalTo: searchWrap.trailingAnchor, constant: -6),
            search.centerYAnchor.constraint(equalTo: searchWrap.centerYAnchor),
        ])

        list.orientation = .vertical; list.alignment = .leading; list.spacing = 1
        list.edgeInsets = NSEdgeInsets(top: 2, left: 8, bottom: 8, right: 8)
        let document = FlippedView()
        document.addSubview(list)
        list.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            list.leadingAnchor.constraint(equalTo: document.leadingAnchor),
            list.trailingAnchor.constraint(equalTo: document.trailingAnchor),
            list.topAnchor.constraint(equalTo: document.topAnchor),
            list.bottomAnchor.constraint(equalTo: document.bottomAnchor),
        ])
        let scroll = NSScrollView()
        scroll.drawsBackground = false; scroll.hasVerticalScroller = true; scroll.scrollerStyle = .overlay
        scroll.documentView = document
        // Scrolling moves rows under a still pointer without mouseExited:
        // re-derive hover from the pointer whenever the list scrolls.
        scroll.contentView.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(self, selector: #selector(listScrolled),
                                               name: NSView.boundsDidChangeNotification, object: scroll.contentView)
        document.translatesAutoresizingMaskIntoConstraints = false
        document.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor).isActive = true

        // MARK: footer — account row + settings, pinned bottom.
        let account = ActionButton(style: .row) { [weak self] in self?.onSettings() }
        account.font = T.ui(13); account.tint = T.labelSecondary
        accountRow = account
        let settings = ActionButton("Settings", symbol: "gearshape", style: .row) { [weak self] in self?.onSettings() }
        settings.font = T.ui(13); settings.tint = T.labelSecondary
        let footer = vertical([account, settings], spacing: 1)
        footer.edgeInsets = NSEdgeInsets(top: 0, left: 8, bottom: 8, right: 8)
        footer.stretchRows()
        let footerDivider = T.hairlineView()

        let middle = vertical([sectionWrap, searchWrap], spacing: 8)
        middle.edgeInsets = NSEdgeInsets(top: 4, left: 0, bottom: 0, right: 0)
        middle.stretchRows()
        logoRow.isHidden = !Self.showsLockup
        let column = vertical([nav, middle], spacing: 16)
        column.stretchRows()

        root.addSubview(logoRow); root.addSubview(column); root.addSubview(scroll)
        root.addSubview(footerDivider); root.addSubview(footer)
        [logoRow, column, scroll, footerDivider, footer].forEach { $0.translatesAutoresizingMaskIntoConstraints = false }
        logoTop = logoRow.topAnchor.constraint(equalTo: root.topAnchor, constant: 44)
        NSLayoutConstraint.activate([
            logoTop,
            logoRow.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 6),
            logoRow.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -6),
            logoRow.heightAnchor.constraint(equalToConstant: Self.showsLockup ? 46 : 0),
            column.topAnchor.constraint(equalTo: logoRow.bottomAnchor, constant: Self.showsLockup ? 10 : 0),
            column.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 6),
            column.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -6),
            scroll.topAnchor.constraint(equalTo: column.bottomAnchor, constant: 10),
            scroll.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 6),
            scroll.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -6),
            scroll.bottomAnchor.constraint(equalTo: footerDivider.topAnchor),
            footerDivider.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            footerDivider.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            footerDivider.bottomAnchor.constraint(equalTo: footer.topAnchor, constant: -6),
            footer.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 6),
            footer.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -6),
            footer.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -8),
            footer.heightAnchor.constraint(greaterThanOrEqualToConstant: 64),
        ])
        // The pane the split sees is a clipping wrapper around `root`. Normally
        // root fills it; while sliding, root keeps its full width pinned to the
        // trailing edge, so the narrowing pane clips it from the left (the
        // Finder/Xcode slide) instead of reflowing and re-truncating every row.
        let wrapper = NSView()
        wrapper.wantsLayer = true
        wrapper.layer?.masksToBounds = true
        wrapper.addSubview(root)
        root.translatesAutoresizingMaskIntoConstraints = false
        rootLeading = root.leadingAnchor.constraint(equalTo: wrapper.leadingAnchor)
        rootSlideWidth = root.widthAnchor.constraint(equalToConstant: 0)
        NSLayoutConstraint.activate([
            rootLeading,
            root.trailingAnchor.constraint(equalTo: wrapper.trailingAnchor),
            root.topAnchor.constraint(equalTo: wrapper.topAnchor),
            root.bottomAnchor.constraint(equalTo: wrapper.bottomAnchor),
        ])
        view = wrapper; reload()
    }

    private var rootLeading = NSLayoutConstraint()
    private var rootSlideWidth = NSLayoutConstraint()

    /// Hold the content at `width` against the trailing edge while the pane
    /// animates, so it slides and clips rather than reflowing.
    func beginSlide(width: CGFloat) {
        _ = view
        rootSlideWidth.constant = width
        rootLeading.isActive = false
        rootSlideWidth.isActive = true
    }
    /// Back to filling the pane.
    func endSlide() {
        _ = view
        rootSlideWidth.isActive = false
        rootLeading.isActive = true
    }

    /// The sidebar opens straight onto its nav, right under the window's top
    /// row: a brand lockup here made a second header. The brand lives in the
    /// empty-state hero and the app icon. Flip to bring the lockup back.
    static let showsLockup = false
    private lazy var logoTop: NSLayoutConstraint = NSLayoutConstraint()

    /// Space for the window's top row (the sidebar runs up behind it).
    func setTopInset(_ height: CGFloat) {
        _ = view
        logoTop.constant = height + 6
    }

    private var searchWork: DispatchWorkItem?
    @objc private func searchChanged() {
        filter = search.stringValue
        // Keystroke-rate reloads rebuild every row + menu; coalesce to one
        // rebuild after typing pauses.
        searchWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.reload() }
        searchWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15, execute: work)
    }

    private static func timeAgo(_ date: Date) -> String {
        let s = Date().timeIntervalSince(date)
        if s < 60 { return "now" }
        if s < 3600 { return "\(Int(s/60))m" }
        if s < 86400 { return "\(Int(s/3600))h" }
        if s < 86400 * 7 { return "\(Int(s/86400))d" }
        let f = DateFormatter(); f.dateFormat = "MMM d"
        return f.string(from: date)
    }

    func reload() {
        guard isViewLoaded else { return }
        list.arrangedSubviews.forEach { list.removeArrangedSubview($0); $0.removeFromSuperview() }
        if let account = accountRow {
            // One Keychain read per reload: each apiKey access is a
            // synchronous SecItemCopyMatching on the main thread.
            let connected = !Settings.shared.apiKey.isEmpty
            account.title = connected ? "DeepSeek API" : "Connect DeepSeek"
            account.symbol = connected ? "checkmark.seal" : "key.horizontal"
            account.tint = connected ? T.labelSecondary : T.accentText
            account.needsDisplay = true
        }

        let sessions = SessionStore.shared.sessions.filter { filter.isEmpty || $0.title.localizedCaseInsensitiveContains(filter) }
        if sessions.isEmpty {
            let emptyWrap = horizontal([T.label(filter.isEmpty ? "No sessions yet" : "Nothing matches", T.ui(12), T.labelTertiary)], spacing: 0)
            emptyWrap.edgeInsets = NSEdgeInsets(top: 6, left: 12, bottom: 6, right: 0)
            list.addArrangedSubview(emptyWrap)
            list.pinRowWidth(emptyWrap)
            return
        }
        for s in sessions.prefix(100) {
            let b = ActionButton(style: .row) { [weak self] in self?.onSelect(.session(s.id)) }
            b.title = s.title
            let timeText = s.running ? "Running" : Self.timeAgo(s.updated)
            let isSelected = s.id == selectedSession
            b.caption = isSelected ? "" : timeText
            b.selected = s.id == selectedSession
            b.tint = b.selected ? T.labelPrimary : T.labelSecondary
            b.toolTip = s.title
            b.menu = sessionMenu(s.id)
            // Visible delete affordance: shown on the selected row and on
            // hover, so deleting never requires discovering the right-click menu.
            // The time caption hides while the trash is visible so the two
            // never overlap.
            let del = ActionButton(symbol: "trash", style: .icon) { [weak self] in self?.onDeleteSession(s.id) }
            del.setFixedSize(24)
            del.toolTip = "Delete session"
            del.setAccessibilityLabel("Delete session")
            del.tint = T.labelSecondary
            del.isHidden = !isSelected
            b.trailingInset = isSelected ? 24 : 0
            b.addSubview(del)
            del.translatesAutoresizingMaskIntoConstraints = false
            NSLayoutConstraint.activate([
                del.trailingAnchor.constraint(equalTo: b.trailingAnchor, constant: -4),
                del.centerYAnchor.constraint(equalTo: b.centerYAnchor),
            ])
            b.onHoverChange = { [weak b] hovered in
                guard let b else { return }
                let show = hovered || isSelected
                del.isHidden = !show
                b.trailingInset = show ? 24 : 0
                b.caption = show ? "" : timeText
                b.needsDisplay = true
            }
            list.addArrangedSubview(b)
            list.pinRowWidth(b)
        }
        // Freshly built rows under a still pointer never get mouseEntered.
        DispatchQueue.main.async { [weak self] in self?.syncRowHover() }
    }

    @objc private func listScrolled() { syncRowHover() }
    private func syncRowHover() {
        for case let row as ActionButton in list.arrangedSubviews { row.syncHoverWithPointer() }
    }

    private func sessionMenu(_ id: UUID) -> NSMenu {
        let m = NSMenu()
        let del = NSMenuItem(title: "Delete Session", action: #selector(deleteRow(_:)), keyEquivalent: "")
        del.target = self; del.representedObject = id
        m.addItem(del)
        return m
    }

    @objc private func deleteRow(_ item: NSMenuItem) {
        if let id = item.representedObject as? UUID { onDeleteSession(id) }
    }

    /// Delete (or ⌘Delete) removes the selected session, unless the
    /// keystroke is text editing in the search field.
    override func keyDown(with event: NSEvent) {
        let isDelete = event.keyCode == 51 || event.keyCode == 117 // kVK_Delete, kVK_ForwardDelete
        guard isDelete, let id = selectedSession else { super.keyDown(with: event); return }
        if let responder = view.window?.firstResponder as? NSView,
           responder is NSText || responder === search {
            super.keyDown(with: event); return
        }
        onDeleteSession(id)
    }

    // MARK: panels

    private func present(_ title: String, content: NSView) {
        closePanel()
        let p = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 460, height: 520),
                        styleMask: [.titled, .closable, .resizable, .fullSizeContentView],
                        backing: .buffered, defer: false)
        p.minSize = NSSize(width: 460, height: 400)
        p.title = title
        p.titlebarAppearsTransparent = true
        p.titleVisibility = .hidden
        p.titlebarSeparatorStyle = .none
        p.isMovableByWindowBackground = true
        // Panels scroll: long plugin/task lists must not clip past the frame.
        let scroll = NSScrollView()
        scroll.drawsBackground = false; scroll.hasVerticalScroller = true; scroll.scrollerStyle = .overlay
        scroll.borderType = .noBorder
        let doc = FlippedView()
        scroll.documentView = doc
        doc.addSubview(content)
        // Fixed document width, no coupling to the clip or window: letting
        // the layout engine relate content width to the live clip width lets
        // it satisfy the system by resizing the panel window itself
        // (observed: 460pt collapsing to a sliver, or stretching unboundedly
        // to fit the longest label).
        doc.translatesAutoresizingMaskIntoConstraints = false
        content.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            doc.leadingAnchor.constraint(equalTo: scroll.contentView.leadingAnchor),
            doc.topAnchor.constraint(equalTo: scroll.contentView.topAnchor),
            doc.widthAnchor.constraint(equalToConstant: 460),
            content.leadingAnchor.constraint(equalTo: doc.leadingAnchor, constant: 24),
            content.trailingAnchor.constraint(equalTo: doc.trailingAnchor, constant: -24),
            content.topAnchor.constraint(equalTo: doc.topAnchor, constant: 24),
            content.bottomAnchor.constraint(equalTo: doc.bottomAnchor, constant: -24),
        ])
        p.contentView = scroll
        p.center()
        p.makeKeyAndOrderFront(nil)
        panel = p
    }

    private func closePanel() { panel?.close(); panel = nil }

    private func confirmUninstall(_ record: PluginRecord) {
        let alert = NSAlert()
        alert.messageText = "Uninstall this plugin?"
        alert.informativeText = "This removes the \(record.name) plugin folder. The plugin's tools and commands stop working."
        alert.addButton(withTitle: "Uninstall"); alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        try? PluginEngine.shared.uninstall(record.id)
        closePanel(); showPlugins()
    }

    private func confirmDeleteAutomation(_ task: AutomationTask) {
        let alert = NSAlert()
        alert.messageText = "Delete this automation?"
        alert.informativeText = "The \(task.title) task stops running. Create tasks again any time by asking in chat."
        alert.addButton(withTitle: "Delete"); alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        Scheduler.shared.remove(id: task.id)
        closePanel(); showAutomations()
    }

    private func setSearchFocus(_ focused: Bool) {
        searchWrap.layer?.borderWidth = focused ? 1.5 : 0
        searchWrap.layer?.borderColor = focused ? T.accent.withAlphaComponent(0.75).cgColor : nil
    }

    func showPlugins() {
        let rows = vertical([], spacing: 10)
        rows.addArrangedSubview(T.label("Plugins", T.ui(20, .semibold)))
        for row in PluginAutomationRows.plugins(intro: "Drop a plugin folder into \(Settings.pluginsDir.path).", onToggle: { [weak self] record in
            try? PluginEngine.shared.setEnabled(record.id, !record.enabled)
            self?.closePanel(); self?.showPlugins()
        }, onDelete: { [weak self] record in self?.confirmUninstall(record) }) {
            rows.addArrangedSubview(row)
        }
        let reload = ActionButton("Reload plugins", symbol: "arrow.clockwise", style: .filled) { [weak self] in
            PluginEngine.shared.reload(); self?.closePanel(); self?.showPlugins()
        }
        rows.addArrangedSubview(NSView())
        rows.addArrangedSubview(horizontal([reload, NSView(), ActionButton("Done") { [weak self] in self?.closePanel() }]))
        present("Plugins", content: rows)
    }

    func showAutomations() {
        let rows = vertical([], spacing: 10)
        rows.addArrangedSubview(T.label("Automations", T.ui(20, .semibold)))
        for row in PluginAutomationRows.automations(
            intro: "Recurring work, handled while Harness is open.",
            onToggle: { [weak self] task in
                Scheduler.shared.setEnabled(task.id, !task.enabled)
                self?.closePanel(); self?.showAutomations()
            },
            onDelete: { [weak self] task in self?.confirmDeleteAutomation(task) }) {
            rows.addArrangedSubview(row)
        }
        rows.addArrangedSubview(NSView())
        let create = ActionButton("Create a task in chat", symbol: "plus", style: .filled) { [weak self] in
            self?.closePanel(); self?.onNewSession()
        }
        rows.addArrangedSubview(horizontal([create, NSView(), ActionButton("Done") { [weak self] in self?.closePanel() }]))
        present("Automations", content: rows)
    }
}

extension SidebarViewController: NSSearchFieldDelegate {
    func controlTextDidBeginEditing(_ notification: Notification) { setSearchFocus(true) }
    func controlTextDidEndEditing(_ notification: Notification) { setSearchFocus(false) }
}
