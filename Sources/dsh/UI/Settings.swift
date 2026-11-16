import AppKit

/// Official-style settings shell: left section nav, right content cards (20px radius).
/// Sections: General, Models & API, Agent loop, Plugins, Automations, Session log.
final class SettingsWindowController: NSWindowController {
    enum Section: Int, CaseIterable {
        case general, models, agent, plugins, automations, log
        var title: String {
            switch self {
            case .general: return "General"
            case .models: return "Models & API"
            case .agent: return "Agent loop"
            case .plugins: return "Plugins"
            case .automations: return "Automations"
            case .log: return "Session log"
            }
        }
        var icon: String {
            switch self {
            case .general: return "gearshape"
            case .models: return "cpu"
            case .agent: return "bolt"
            case .plugins: return "puzzlepiece.extension"
            case .automations: return "clock.arrow.circlepath"
            case .log: return "doc.text.magnifyingglass"
            }
        }
    }

    private let keyField = NSSecureTextField()
    private let baseField = NSTextField()
    private let autonomy = NSPopUpButton()
    private let profilePopup = NSPopUpButton()
    private let sandboxPopup = NSPopUpButton()
    private let secretsSwitch = NSSwitch()
    private let networkSwitch = NSSwitch()
    private let sandboxCaption = SettingsWindowController.caption()

    /// Secondary text that wraps instead of truncating.
    private static func caption() -> WrappingLabel {
        let l = WrappingLabel()
        l.font = T.ui(12); l.textColor = T.labelSecondary
        return l
    }
    private let profileCaption = SettingsWindowController.caption()
    private let status = T.label("", T.ui(12), T.labelSecondary)
    private let workspaceLabel = T.label("", T.ui(13), T.labelPrimary)
    private let appearanceControl = NSSegmentedControl(labels: ["System", "Light", "Dark"], trackingMode: .selectOne, target: nil, action: nil)
    private var observer: NSObjectProtocol?
    private var settingsObserver: NSObjectProtocol?
    private let contentHost = NSView()
    private var sectionButtons: [Section: ActionButton] = [:]
    private var modelStack: NSStackView?

    init() {
        let window = NSWindow(contentRect: .init(x: 0, y: 0, width: 880, height: 580),
                              styleMask: [.titled, .closable, .fullSizeContentView], backing: .buffered, defer: false)
        window.minSize = NSSize(width: 880, height: 400)
        window.title = "Settings"; window.titlebarAppearsTransparent = true
        window.titlebarSeparatorStyle = .none
        window.titleVisibility = .hidden
        super.init(window: window)

        let root = TintedView(T.bgBase)
        window.contentView = root

        // MARK: left nav.
        let navTitle = T.label("Settings", T.ui(15, .semibold), T.labelPrimary)
        let navStack = NSStackView()
        navStack.orientation = .vertical; navStack.alignment = .leading; navStack.spacing = 2
        navStack.edgeInsets = NSEdgeInsets(top: 0, left: 8, bottom: 0, right: 8)
        for s in Section.allCases {
            let b = ActionButton(s.title, symbol: s.icon, style: .nav) { [weak self] in self?.select(s) }
            b.tint = T.labelSecondary
            b.setAccessibilityLabel(s.title)
            sectionButtons[s] = b
            navStack.addArrangedSubview(b)
        }
        navStack.stretchRows()
        let navColumn = vertical([navTitle, navStack], spacing: 14)
        // Insets first: stretchRows() pins row widths from the insets, and
        // oversized rows get clamped to the stack edge (clipped title).
        navColumn.edgeInsets = NSEdgeInsets(top: 28, left: 20, bottom: 20, right: 12)
        navColumn.stretchRows()
        let nav = TintedView(T.sidebarFill)
        nav.addSubview(navColumn)
        navColumn.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            navColumn.topAnchor.constraint(equalTo: nav.topAnchor),
            navColumn.leadingAnchor.constraint(equalTo: nav.leadingAnchor),
            navColumn.trailingAnchor.constraint(equalTo: nav.trailingAnchor),
            navColumn.bottomAnchor.constraint(equalTo: nav.bottomAnchor),
            nav.widthAnchor.constraint(equalToConstant: 210),
        ])
        let navDivider = TintedView(T.borderL1)
        navDivider.widthAnchor.constraint(equalToConstant: 0.5).isActive = true

        // MARK: content host. No Done bar: macOS settings apply as you change
        // them and close with the window button or ⌘W. (The API key commits
        // through its own "Save & fetch models" button.)
        contentHost.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(nav); root.addSubview(navDivider); root.addSubview(contentHost)
        [nav, navDivider].forEach { $0.translatesAutoresizingMaskIntoConstraints = false }
        NSLayoutConstraint.activate([
            nav.topAnchor.constraint(equalTo: root.topAnchor),
            nav.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            nav.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            navDivider.leadingAnchor.constraint(equalTo: nav.trailingAnchor),
            navDivider.topAnchor.constraint(equalTo: root.topAnchor),
            navDivider.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            contentHost.topAnchor.constraint(equalTo: root.topAnchor, constant: 28),
            contentHost.leadingAnchor.constraint(equalTo: navDivider.trailingAnchor, constant: 28),
            contentHost.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -28),
            contentHost.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -24),
        ])

        buildFields()
        select(.general)
        window.center()
        observer = NotificationCenter.default.addObserver(forName: .modelsChanged, object: nil, queue: .main) { [weak self] _ in self?.updateStatus() }
        settingsObserver = NotificationCenter.default.addObserver(forName: .settingsChanged, object: nil, queue: .main) { [weak self] _ in
            self?.syncFields()
        }
        updateStatus()
    }
    required init?(coder: NSCoder) { fatalError() }
    deinit {
        if let observer { NotificationCenter.default.removeObserver(observer) }
        if let settingsObserver { NotificationCenter.default.removeObserver(settingsObserver) }
    }

    override func showWindow(_ sender: Any?) {
        syncFields()
        super.showWindow(sender)
    }

    // MARK: - fields (built once, hosted per section)

    private func buildFields() {
        keyField.stringValue = Settings.shared.apiKey
        keyField.placeholderString = "sk-..."
        keyField.setAccessibilityLabel("API key")
        baseField.stringValue = Settings.shared.baseURL
        baseField.setAccessibilityLabel("API endpoint")
        for field in [keyField as NSTextField, baseField] {
            field.font = T.ui(13); field.bezelStyle = .roundedBezel
            field.controlSize = .regular
            field.heightAnchor.constraint(equalToConstant: 32).isActive = true
        }
        autonomy.addItems(withTitles: Autonomy.allCases.map(\.label))
        autonomy.selectItem(at: Autonomy.allCases.firstIndex(of: Settings.shared.autonomy) ?? 1)
        autonomy.target = self; autonomy.action = #selector(autonomyChanged)
        profilePopup.removeAllItems()
        profilePopup.addItems(withTitles: AgentProfiles.all.map { $0.id })
        profilePopup.selectItem(withTitle: Settings.shared.agentProfile)
        profilePopup.target = self; profilePopup.action = #selector(profileChanged)
        profilePopup.font = T.ui(13)
        updateProfileCaption()
        autonomy.font = T.ui(13)
        sandboxPopup.addItems(withTitles: SandboxMode.allCases.map(\.label))
        sandboxPopup.selectItem(at: SandboxMode.allCases.firstIndex(of: Settings.shared.sandboxMode) ?? 1)
        sandboxPopup.target = self; sandboxPopup.action = #selector(sandboxChanged)
        sandboxPopup.font = T.ui(13)
        secretsSwitch.state = Settings.shared.sandboxProtectSecrets ? .on : .off
        secretsSwitch.target = self; secretsSwitch.action = #selector(sandboxChanged)
        secretsSwitch.setAccessibilityLabel("Protect credentials")
        networkSwitch.state = Settings.shared.sandboxNetwork ? .on : .off
        networkSwitch.target = self; networkSwitch.action = #selector(sandboxChanged)
        networkSwitch.setAccessibilityLabel("Network access for commands")
        updateSandboxCaption()
        keyField.widthAnchor.constraint(greaterThanOrEqualToConstant: 240).isActive = true
        baseField.widthAnchor.constraint(greaterThanOrEqualToConstant: 240).isActive = true
        workspaceLabel.stringValue = Settings.shared.workspace
        workspaceLabel.lineBreakMode = .byTruncatingMiddle
        workspaceLabel.toolTip = Settings.shared.workspace
        workspaceLabel.font = T.mono(12); workspaceLabel.textColor = T.labelSecondary
        appearanceControl.target = self; appearanceControl.action = #selector(appearanceChanged)
        appearanceControl.selectedSegment = ["System", "Light", "Dark"].firstIndex(of: Settings.shared.appearance) ?? 0
        appearanceControl.setAccessibilityLabel("Appearance")
    }

    private func syncFields() {
        // Never rewrite a field the user is editing: an unrelated settings
        // change (autonomy chip, profile pick) must not clobber typed text.
        if keyField.currentEditor() == nil { keyField.stringValue = Settings.shared.apiKey }
        if baseField.currentEditor() == nil { baseField.stringValue = Settings.shared.baseURL }
        autonomy.selectItem(at: Autonomy.allCases.firstIndex(of: Settings.shared.autonomy) ?? 1)
        profilePopup.selectItem(withTitle: Settings.shared.agentProfile)
        workspaceLabel.stringValue = Settings.shared.workspace
        workspaceLabel.toolTip = Settings.shared.workspace
        appearanceControl.selectedSegment = ["System", "Light", "Dark"].firstIndex(of: Settings.shared.appearance) ?? 0
        updateProfileCaption()
        updateStatus()
    }

    @objc private func appearanceChanged() {
        let titles = ["System", "Light", "Dark"]
        guard titles.indices.contains(appearanceControl.selectedSegment) else { return }
        let title = titles[appearanceControl.selectedSegment]
        Settings.shared.appearance = title
        NSApp.appearance = title == "System" ? nil : NSAppearance(named: title == "Light" ? .aqua : .darkAqua)
    }

    // MARK: - section switching

    func select(_ s: Section) {
        for (sec, b) in sectionButtons {
            b.selected = sec == s
            b.tint = sec == s ? T.labelPrimary : T.labelSecondary
            b.needsDisplay = true
        }
        contentHost.subviews.forEach { $0.removeFromSuperview() }
        let content = NSScrollView()
        content.drawsBackground = false; content.hasVerticalScroller = true; content.scrollerStyle = .overlay
        let doc = FlippedView()
        content.documentView = doc
        // Fixed document width, no coupling to the clip or window: relating
        // content width to the live clip width lets the layout engine resize
        // the settings window itself (observed: stretching unboundedly to fit
        // the longest label). 613pt is the content width at the 880pt design
        // size; the window keeps a matching minimum size below.
        doc.translatesAutoresizingMaskIntoConstraints = false
        doc.leadingAnchor.constraint(equalTo: content.contentView.leadingAnchor).isActive = true
        doc.topAnchor.constraint(equalTo: content.contentView.topAnchor).isActive = true
        doc.widthAnchor.constraint(equalToConstant: 613).isActive = true
        let stack = buildSection(s)
        doc.addSubview(stack)
        stack.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: doc.topAnchor, constant: 8),
            stack.leadingAnchor.constraint(equalTo: doc.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: doc.trailingAnchor),
            stack.bottomAnchor.constraint(equalTo: doc.bottomAnchor, constant: -8),
        ])
        contentHost.addSubview(content)
        content.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            content.topAnchor.constraint(equalTo: contentHost.topAnchor),
            content.leadingAnchor.constraint(equalTo: contentHost.leadingAnchor),
            content.trailingAnchor.constraint(equalTo: contentHost.trailingAnchor),
            content.bottomAnchor.constraint(equalTo: contentHost.bottomAnchor),
        ])
    }

    /// Card container matching the official 20px settings cards.
    private func card(_ rows: [NSView], spacing: CGFloat = 0) -> NSView {
        let inner = NSStackView(views: rows)
        inner.orientation = .vertical; inner.alignment = .leading; inner.spacing = spacing
        inner.edgeInsets = NSEdgeInsets(top: 16, left: 18, bottom: 16, right: 18)
        inner.stretchRows()
        let surface = Surface(T.bgLayer2, radius: 12, stroke: T.borderL1c)
        wantsLayerFix(surface)
        surface.addSubview(inner)
        inner.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            inner.topAnchor.constraint(equalTo: surface.topAnchor),
            inner.leadingAnchor.constraint(equalTo: surface.leadingAnchor),
            inner.trailingAnchor.constraint(equalTo: surface.trailingAnchor),
            inner.bottomAnchor.constraint(equalTo: surface.bottomAnchor),
        ])
        surface.addStrokeOverlay()
        return surface
    }
    private func wantsLayerFix(_ v: NSView) {
        v.wantsLayer = true
        v.layer?.cornerRadius = 12
        v.layer?.masksToBounds = true
    }

    /// Title + optional description row used at the top of each section.
    private func heading(_ title: String, _ sub: String? = nil) -> NSView {
        var rows: [NSView] = [T.label(title, T.ui(20, .semibold), T.labelPrimary)]
        if let sub { rows.append(T.label(sub, T.ui(12.5), T.labelSecondary)) }
        let col = vertical(rows, spacing: 4)
        col.alignment = .leading
        return col
    }

    /// Label + control row inside a card.
    private func row(_ title: String, _ detail: String? = nil, control: NSView? = nil) -> NSView {
        let labels = vertical([T.label(title, T.ui(13, .medium), T.labelPrimary)]
            + (detail.map { [T.label($0, T.ui(12), T.labelSecondary)] } ?? []), spacing: 2)
        labels.alignment = .leading
        if let control {
            let row = horizontal([labels, NSView(), control], spacing: 12)
            row.alignment = .centerY
            labels.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            return row
        }
        return labels
    }

    private func buildSection(_ s: Section) -> NSStackView {
        let stack = NSStackView()
        stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 16
        stack.edgeInsets = NSEdgeInsets(top: 0, left: 0, bottom: 0, right: 0)
        switch s {
        case .general: stack.addArrangedSubview(generalCard())
        case .models: stack.addArrangedSubview(modelsCard())
        case .agent:
            stack.addArrangedSubview(agentCard())
            stack.addArrangedSubview(sandboxCard())
        case .plugins: stack.addArrangedSubview(pluginsCard())
        case .automations: stack.addArrangedSubview(automationsCard())
        case .log: stack.addArrangedSubview(logCard())
        }
        stack.addArrangedSubview(NSView())
        stack.stretchRows()
        return stack
    }

    private func generalCard() -> NSView {
        let choose = ActionButton("Choose…", style: .filled) { [weak self] in self?.pickWorkspace() }
        let content = card([
            row("Workspace", "Where the agent reads and writes files.", control: horizontal([workspaceLabel, choose], spacing: 8)),
            row("Appearance", "Match the system, or stay light or dark.", control: appearanceControl),
        ], spacing: 14)
        return wrapSection(heading("General", "Workspace and appearance."), content)
    }

    private func modelsCard() -> NSView {
        let getKey = NSButton(title: "Get an API key ↗", target: self, action: #selector(openPortal))
        getKey.isBordered = false; getKey.font = T.ui(12); getKey.contentTintColor = T.accentText
        let refresh = ActionButton("Refresh models", symbol: "arrow.clockwise", style: .filled) { ModelCatalog.shared.refresh() }
        let save = ActionButton("Save & fetch models", symbol: "arrow.right", style: .primary) { [weak self] in self?.save() }
        let buttons = horizontal([getKey, NSView(), refresh, save], spacing: 8)
        let privacy = WrappingLabel()
        privacy.font = T.ui(12); privacy.textColor = T.labelSecondary
        privacy.stringValue = "Your key is stored in macOS Keychain. Requests go directly to your API endpoint. No account sign-in or intermediary."
        let connection = card([
            row("API key", "DeepSeek API key.", control: keyField),
            row("Endpoint", "OpenAI-compatible base URL.", control: baseField),
            status,
            privacy,
            buttons,
        ], spacing: 14)
        modelStack = NSStackView()
        modelStack!.orientation = .vertical; modelStack!.alignment = .leading; modelStack!.spacing = 1
        let list = card([
            T.label("Default model", T.ui(13, .medium), T.labelPrimary),
            T.label("Used for new sessions and the composer.", T.ui(12), T.labelSecondary),
            modelStack!,
        ], spacing: 8)
        let col = vertical([
            heading("Models & API", "Connect to DeepSeek and choose a model."),
            connection,
            list,
        ], spacing: 14)
        col.stretchRows()
        rebuildModelRows()
        return col
    }

    private func rebuildModelRows() {
        guard let stack = modelStack else { return }
        stack.arrangedSubviews.forEach { stack.removeArrangedSubview($0); $0.removeFromSuperview() }
        switch ModelCatalog.shared.state {
        case .disconnected:
            stack.addArrangedSubview(T.label("Add your API key above to fetch models.", T.ui(12), T.labelSecondary))
        case .loading:
            stack.addArrangedSubview(T.label("Fetching models…", T.ui(12), T.labelSecondary))
        case .failed(let error):
            stack.addArrangedSubview(T.label(error, T.ui(12), T.errorPrimary))
        case .ready:
            let models = ModelCatalog.shared.models
            if models.isEmpty {
                stack.addArrangedSubview(T.label("No models returned by the endpoint.", T.ui(12), T.labelSecondary))
            }
            for m in models.prefix(200) {
                let current = Settings.shared.model == m
                let b = ActionButton(m, symbol: current ? "checkmark.circle.fill" : "circle", style: .row) { [weak self] in self?.pickModel(m) }
                b.selected = current
                b.font = T.mono(12)
                b.toolTip = current ? "\(m) · default" : m
                stack.addArrangedSubview(b)
                stack.pinRowWidth(b)
            }
        }
    }

    private func pickModel(_ m: String) {
        Settings.shared.model = m
        NotificationCenter.default.post(name: .settingsChanged, object: nil)
        rebuildModelRows()
    }

    private func agentCard() -> NSView {
        updateProfileCaption()
        let content = card([
            row("Agent profile", "Upstream dsh preset, built in as is.", control: profilePopup),
            row("Tool permissions", "How much the agent may do without asking.", control: autonomy),
            profileCaption,
        ], spacing: 14)
        return wrapSection(heading("Agent loop", "Autonomy and approval behavior."), content)
    }

    private func sandboxCard() -> NSView {
        let content = card([
            row("Mode", "Where shell commands can make changes.", control: sandboxPopup),
            row("Protect credentials", "Block ~/.ssh, ~/.aws, Keychains, mail, browser data.", control: secretsSwitch),
            row("Network access", "Commands can reach the internet.", control: networkSwitch),
            sandboxCaption,
        ], spacing: 14)
        return wrapSection(heading("Sandbox", "What shell commands and plugins can touch."), content)
    }

    private func updateProfileCaption() {
        let profile = AgentProfiles.profile(id: Settings.shared.agentProfile)
        profileCaption.stringValue = "Upstream preset \(profile.id) · \(AgentProfiles.capabilitySummary(profile))." +
            (profile.unsupportedTools.isEmpty ? "" : " No native equivalent for: \(profile.unsupportedTools.joined(separator: ", ")).")
    }

    @objc private func profileChanged() {
        Settings.shared.agentProfile = profilePopup.titleOfSelectedItem ?? "standard"
        updateProfileCaption()
        NotificationCenter.default.post(name: .settingsChanged, object: nil)
    }

    private func pluginsCard() -> NSView {
        var rows = PluginAutomationRows.plugins(
            intro: "Drop a plugin folder into \(Settings.pluginsDir.path), then reload.",
            onToggle: { [weak self] record in
                try? PluginEngine.shared.setEnabled(record.id, !record.enabled)
                self?.select(.plugins)
            },
            onDelete: { [weak self] record in self?.confirmUninstall(record) }
        )
        let reload = ActionButton("Reload plugins", symbol: "arrow.clockwise", style: .filled) { [weak self] in
            PluginEngine.shared.reload(); self?.select(.plugins)
        }
        rows.append(horizontal([reload, NSView()]))
        let inner = card(rows, spacing: 10)
        return wrapSection(heading("Plugins", "Extensions that add tools and commands."), inner)
    }

    private func automationsCard() -> NSView {
        let rows = PluginAutomationRows.automations(
            intro: "Recurring work the agent handles while Harness is open. Create tasks by asking in chat.",
            onToggle: { [weak self] task in
                Scheduler.shared.setEnabled(task.id, !task.enabled)
                self?.select(.automations)
            },
            onDelete: { [weak self] task in self?.confirmDeleteAutomation(task) }
        )
        let inner = card(rows, spacing: 10)
        return wrapSection(heading("Automations", "Scheduled agent tasks."), inner)
    }

    private func logCard() -> NSView {
        let path = Settings.sessionsDir.path
        let label = T.label(path, T.mono(11), T.labelSecondary)
        label.lineBreakMode = .byTruncatingMiddle
        let reveal = ActionButton("Reveal in Finder", symbol: "folder", style: .filled) {
            NSWorkspace.shared.activateFileViewerSelecting([Settings.sessionsDir])
        }
        let count = SessionStore.shared.sessions.count
        let inner = card([
            row("Sessions", "\(count) saved conversation\(count == 1 ? "" : "s").", control: reveal),
            label,
        ], spacing: 12)
        return wrapSection(heading("Session log", "Where conversations are stored."), inner)
    }

    /// Section header + card, matching the official settings page rhythm.
    private func wrapSection(_ header: NSView, _ content: NSView) -> NSView {
        let col = vertical([header, content], spacing: 14)
        col.stretchRows()
        return col
    }

    private func confirmUninstall(_ record: PluginRecord) {
        let alert = NSAlert()
        alert.messageText = "Uninstall this plugin?"
        alert.informativeText = "This removes the \(record.name) plugin folder. The plugin's tools and commands stop working."
        alert.addButton(withTitle: "Uninstall"); alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        try? PluginEngine.shared.uninstall(record.id)
        select(.plugins)
    }

    private func confirmDeleteAutomation(_ task: AutomationTask) {
        let alert = NSAlert()
        alert.messageText = "Delete this automation?"
        alert.informativeText = "The \(task.title) task stops running. Create tasks again any time by asking in chat."
        alert.addButton(withTitle: "Delete"); alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        Scheduler.shared.remove(id: task.id)
        select(.automations)
    }

    private func pickWorkspace() {
        let panel = NSOpenPanel(); panel.canChooseDirectories = true; panel.canChooseFiles = false
        panel.prompt = "Use workspace"
        if panel.runModal() == .OK, let url = panel.url {
            Settings.shared.workspace = url.path
            workspaceLabel.stringValue = url.path
            workspaceLabel.toolTip = url.path
            NotificationCenter.default.post(name: .settingsChanged, object: nil)
        }
    }

    private func updateStatus() {
        status.toolTip = nil
        switch ModelCatalog.shared.state {
        case .disconnected: status.stringValue = "Add your key to discover available models."; status.textColor = T.labelSecondary
        case .loading: status.stringValue = "Fetching available models..."; status.textColor = T.labelSecondary
        case .ready: status.stringValue = "Connected · \(ModelCatalog.shared.models.count) models available"; status.textColor = T.successText
        case .failed(let error): status.stringValue = error; status.textColor = T.errorPrimary; status.toolTip = error
        }
        rebuildModelRows()
    }
    private func save() {
        let key = keyField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let base = baseField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let client = DeepSeekClient(); client.config.baseURL = base
        do { _ = try client.endpoint("models") } catch {
            status.stringValue = error.localizedDescription; status.textColor = T.errorPrimary; return
        }
        Settings.shared.apiKey = key; Settings.shared.baseURL = base
        NotificationCenter.default.post(name: .settingsChanged, object: nil)
        if let keychainError = Settings.shared.keychainError {
            status.stringValue = keychainError; status.textColor = T.errorPrimary
        } else {
            updateStatus()
        }
    }
    @objc private func sandboxChanged() {
        let i = sandboxPopup.indexOfSelectedItem
        if SandboxMode.allCases.indices.contains(i) { Settings.shared.sandboxMode = SandboxMode.allCases[i] }
        Settings.shared.sandboxProtectSecrets = secretsSwitch.state == .on
        Settings.shared.sandboxNetwork = networkSwitch.state == .on
        updateSandboxCaption()
        NotificationCenter.default.post(name: .settingsChanged, object: nil)
    }

    private func updateSandboxCaption() {
        let mode = Settings.shared.sandboxMode
        let confined = mode != .fullAccess
        secretsSwitch.isEnabled = confined; networkSwitch.isEnabled = confined
        var text = mode.detail + (confined ? " Enforced by macOS, even after you approve a command." : "")
        if confined { text += " The agent can ask to run one command outside it; you're asked every time." }
        if confined && !SandboxPolicy.isAvailable { text = "The sandbox isn't working on this Mac, so shell commands are blocked. Choose Full access to run them unconfined." }
        sandboxCaption.stringValue = text
    }

    @objc private func autonomyChanged() {
        let i = autonomy.indexOfSelectedItem
        guard Autonomy.allCases.indices.contains(i) else { return }
        Settings.shared.autonomy = Autonomy.allCases[i]
        NotificationCenter.default.post(name: .settingsChanged, object: nil)
    }
    @objc private func openPortal() { NSWorkspace.shared.open(URL(string: "https://platform.deepseek.com/api_keys")!) }
}
