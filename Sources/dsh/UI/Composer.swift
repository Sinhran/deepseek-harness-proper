import AppKit

/// Label that never eats clicks meant for the view beneath it.
final class PassthroughLabel: NSTextField {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

/// Editor that sends on Return and accepts dropped files.
final class PromptTextView: NSTextView {
    var onSubmit: () -> Void = {}
    var onDrop: ([URL]) -> Void = { _ in }
    override func keyDown(with event: NSEvent) {
        // Return (36) and keypad Enter (76) both submit; Shift makes a newline.
        let submitKey = event.keyCode == 36 || event.keyCode == 76
        if submitKey && !event.modifierFlags.contains(.shift) && !hasMarkedText() {
            onSubmit()
        } else { super.keyDown(with: event) }
    }
    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        sender.draggingPasteboard.canReadObject(forClasses: [NSURL.self],
                                              options: [.urlReadingFileURLsOnly: true]) ? .copy : []
    }
    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        let urls = sender.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
        if !urls.isEmpty { onDrop(urls); return true }
        return false
    }
}

/// The official send/stop control: a 34px info-blue circle.
/// Glyphs: up-arrow (send), rounded square (stop), spinning arc (sending).
final class SendButton: NSButton {
    enum Mode { case send, stop, sending }
    var mode: Mode = .send { didSet { needsDisplay = true; syncSpin() } }
    var onPress: () -> Void = {}
    private var hover = false
    private var spin: Timer?
    private var spinAngle: CGFloat = 0

    init(action: @escaping () -> Void = {}) {
        onPress = action
        super.init(frame: .zero)
        isBordered = false; target = self; self.action = #selector(go)
        widthAnchor.constraint(equalToConstant: 34).isActive = true
        heightAnchor.constraint(equalToConstant: 34).isActive = true
        setAccessibilityLabel("Send message")
    }
    required init?(coder: NSCoder) { fatalError() }
    @objc private func go() { onPress() }

    override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); syncSpin() }
    override func becomeFirstResponder() -> Bool { let r = super.becomeFirstResponder(); needsDisplay = true; return r }
    override func resignFirstResponder() -> Bool { let r = super.resignFirstResponder(); needsDisplay = true; return r }
    private func syncSpin() {
        // Reduce Motion also stops a timer already running, not just the
        // next schedule.
        let shouldSpin = mode == .sending
            && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        if !shouldSpin, let sp = spin { sp.invalidate(); spin = nil }
        if shouldSpin, spin == nil {
            spin = Timer.scheduledTimer(withTimeInterval: 0.07, repeats: true) { [weak self] _ in
                guard let self else { return }
                self.spinAngle += .pi / 8
                self.needsDisplay = true
            }
        }
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.inVisibleRect, .activeAlways, .mouseEnteredAndExited],
                                      owner: self, userInfo: nil))
    }
    override func mouseEntered(with event: NSEvent) { hover = true; needsDisplay = true }
    override func mouseExited(with event: NSEvent) { hover = false; needsDisplay = true }
    override func viewDidChangeEffectiveAppearance() { super.viewDidChangeEffectiveAppearance(); needsDisplay = true }

    override func draw(_ dirtyRect: NSRect) {
        let rect = bounds.insetBy(dx: 0.5, dy: 0.5)
        let circle = NSBezierPath(ovalIn: rect)
        if !isEnabled {
            T.selector.setFill(); circle.fill()
            T.labelTertiary.setStroke()
            let cx = bounds.midX, cy = bounds.midY
            let p = NSBezierPath()
            p.lineWidth = 1.8; p.lineCapStyle = .round; p.lineJoinStyle = .round
            p.move(to: NSPoint(x: cx, y: cy + 4.6)); p.line(to: NSPoint(x: cx, y: cy - 4.2))
            p.move(to: NSPoint(x: cx - 3.6, y: cy - 1.2)); p.line(to: NSPoint(x: cx, y: cy - 4.6)); p.line(to: NSPoint(x: cx + 3.6, y: cy - 1.2))
            p.stroke()
            return
        }
        (hover ? T.infoHover : T.infoFill).setFill()
        circle.fill()
        let cx = bounds.midX, cy = bounds.midY
        // Light fill: dark ink glyph in both themes for contrast.
        let white = T.rgb(0x16150F)
        switch mode {
        case .send:
            // Up arrow: shaft + head, ~14px.
            white.setStroke()
            let p = NSBezierPath()
            p.lineWidth = 1.8; p.lineCapStyle = .round; p.lineJoinStyle = .round
            p.move(to: NSPoint(x: cx, y: cy + 4.6))
            p.line(to: NSPoint(x: cx, y: cy - 4.2))
            p.move(to: NSPoint(x: cx - 3.6, y: cy - 1.2))
            p.line(to: NSPoint(x: cx, y: cy - 4.6))
            p.line(to: NSPoint(x: cx + 3.6, y: cy - 1.2))
            p.stroke()
        case .stop:
            // 10x10 rounded square, rx 3.
            white.setFill()
            NSBezierPath(roundedRect: NSRect(x: cx - 5, y: cy - 5, width: 10, height: 10),
                         xRadius: 3, yRadius: 3).fill()
        case .sending:
            // Spinner: light track + bright arc.
            white.withAlphaComponent(0.35).setStroke()
            let track = NSBezierPath(ovalIn: rect.insetBy(dx: 10, dy: 10))
            track.lineWidth = 2; track.stroke()
            white.setStroke()
            let arc = NSBezierPath()
            arc.lineWidth = 2; arc.lineCapStyle = .round
            arc.appendArc(withCenter: NSPoint(x: cx, y: cy), radius: 7,
                          startAngle: spinAngle * 180 / .pi,
                          endAngle: spinAngle * 180 / .pi + 270, clockwise: true)
            arc.stroke()
        }
        if window?.firstResponder == self {
            T.labelPrimary.setStroke()
            let ring = NSBezierPath(ovalIn: bounds.insetBy(dx: 1, dy: 1))
            ring.lineWidth = 2
            ring.stroke()
        }
    }
    deinit { spin?.invalidate() }
}

/// Rounded surface that also accepts file drops (the composer card).
final class DropSurface: Surface {
    var onDropURLs: ([URL]) -> Void = { _ in }
    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation { .copy }
    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        let urls = sender.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
        if !urls.isEmpty { onDropURLs(urls); return true }
        return false
    }
}

/// The writing surface: one card containing the editor, the controls, and the send action.
/// Metrics follow the official InputBar: 16px radius, input-major fill, soft elevation,
/// 12px gaps, sticky bottom dock.
final class InputBar: View, NSTextViewDelegate {
    var onSend: (String, [Attachment]) -> Bool = { _, _ in false }
    var onModelChange: (String) -> Void = { _ in }
    var onProfileChange: (String) -> Void = { _ in }
    var onStop: () -> Void = {}
    var onAutonomyChange: (Autonomy) -> Void = { _ in }

    let textView = PromptTextView()
    private let card = DropSurface(T.inputMajor, radius: 16, stroke: T.borderL2)
    private let sendBtn = SendButton()
    private let modelChip = SelectChip()
    private let profileChip = SelectChip()
    private let autonomyChip = SelectChip()
    private let editorScroll = NSScrollView()
    private let placeholder: NSTextField = {
        // Click-transparent: it overlays the editor's first line, so hit
        // testing to itself would eat the clicks that should focus it.
        let l = PassthroughLabel(labelWithString: "Describe what you want to build.  / commands, @ files")
        l.font = T.ui(14); l.textColor = T.labelCaption; l.lineBreakMode = .byTruncatingTail
        return l
    }()
    private let attachStrip = NSStackView()
    private var editorHeight: NSLayoutConstraint!
    private var attachments: [Attachment] = []
    private var pendingAttachments = 0
    private var attachmentGeneration = 0
    private var attachmentTasks: [UUID: Task<Void, Never>] = [:]
    private var running = false
    private var sending = false
    private(set) var selectedModel: String?
    private(set) var selectedProfile = "standard"
    private let speech = SpeechInput()
    private let mic = ActionButton(symbol: "mic", style: .icon)
    private let add = ActionButton(symbol: "plus", style: .icon)
    private var speechBase = ""
    private var speechToken = 0

    /// Max width of the card itself (official: chat content width + 32px).
    var maxCardWidth: CGFloat = 780 {
        didSet { cardWidthCap?.constant = maxCardWidth }
    }
    private var cardWidthCap: NSLayoutConstraint?
    /// Hero (empty-state) composer gets a taller editor minimum.
    var heroMode = false { didSet { updateEditor() } }

    init() {
        super.init(frame: .zero)
        card.elevation = .soft
        addSubview(card)
        card.translatesAutoresizingMaskIntoConstraints = false

        textView.isRichText = false; textView.drawsBackground = false
        textView.font = T.ui(14); textView.textColor = T.labelPrimary
        textView.insertionPointColor = T.accent
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.textContainerInset = NSSize(width: 8, height: 4)
        textView.textContainer?.lineFragmentPadding = 0
        textView.isHorizontallyResizable = false; textView.isVerticallyResizable = true
        textView.textContainer?.widthTracksTextView = true
        textView.autoresizingMask = [.width]
        textView.delegate = self; textView.allowsUndo = true
        textView.setAccessibilityLabel("Message")
        textView.onSubmit = { [weak self] in self?.submit() }
        textView.onDrop = { [weak self] in self?.attach($0) }
        textView.registerForDraggedTypes([.fileURL])
        editorScroll.documentView = textView
        editorScroll.hasVerticalScroller = true; editorScroll.scrollerStyle = .overlay
        editorScroll.drawsBackground = false
        editorScroll.translatesAutoresizingMaskIntoConstraints = false
        let editorWrap = NSView()
        editorWrap.addSubview(editorScroll)
        NSLayoutConstraint.activate([
            editorScroll.topAnchor.constraint(equalTo: editorWrap.topAnchor),
            editorScroll.bottomAnchor.constraint(equalTo: editorWrap.bottomAnchor),
            editorScroll.leadingAnchor.constraint(equalTo: editorWrap.leadingAnchor, constant: 6),
            editorScroll.trailingAnchor.constraint(equalTo: editorWrap.trailingAnchor),
        ])
        editorHeight = editorScroll.heightAnchor.constraint(equalToConstant: heroMinHeight)
        editorHeight.isActive = true

        // Attachments strip — official file chips (24px, hairline, radius 8).
        attachStrip.orientation = .horizontal; attachStrip.spacing = 6; attachStrip.isHidden = true
        // Toolbar row: tools left, trailing right — padding 2/8/6.
        let tools = horizontal([add, mic, autonomyChip], spacing: 8)
        tools.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let trailing = horizontal([profileChip, modelChip, sendBtn], spacing: 12)
        let toolbar = NSView()
        toolbar.addSubview(tools); toolbar.addSubview(trailing)
        tools.translatesAutoresizingMaskIntoConstraints = false
        trailing.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            tools.leadingAnchor.constraint(equalTo: toolbar.leadingAnchor, constant: 8),
            tools.topAnchor.constraint(equalTo: toolbar.topAnchor, constant: 2),
            tools.bottomAnchor.constraint(equalTo: toolbar.bottomAnchor, constant: -6),
            trailing.trailingAnchor.constraint(equalTo: toolbar.trailingAnchor, constant: -8),
            trailing.centerYAnchor.constraint(equalTo: toolbar.centerYAnchor),
            tools.trailingAnchor.constraint(lessThanOrEqualTo: trailing.leadingAnchor, constant: -12),
        ])
        toolbar.heightAnchor.constraint(equalToConstant: 42).isActive = true

        let inner = vertical([attachStrip, editorWrap, toolbar], spacing: 12)
        inner.setCustomSpacing(0, after: attachStrip) // hidden until a file is attached
        inner.edgeInsets = NSEdgeInsets(top: 8, left: 0, bottom: 0, right: 0)
        card.addSubview(inner); inner.pin(to: card)
        attachStrip.widthAnchor.constraint(equalTo: inner.widthAnchor, constant: -24).isActive = true
        // The toolbar manages its own horizontal padding.
        toolbar.widthAnchor.constraint(equalTo: inner.widthAnchor).isActive = true
        editorWrap.widthAnchor.constraint(equalTo: inner.widthAnchor).isActive = true

        // Card metrics: width = min(self - 32, maxCardWidth), centered.
        card.centerXAnchor.constraint(equalTo: centerXAnchor).isActive = true
        card.topAnchor.constraint(equalTo: topAnchor).isActive = true
        card.bottomAnchor.constraint(equalTo: bottomAnchor).isActive = true
        card.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor, constant: 16).isActive = true
        card.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -16).isActive = true
        cardWidthCap = card.widthAnchor.constraint(lessThanOrEqualToConstant: maxCardWidth)
        cardWidthCap?.priority = .required
        cardWidthCap?.isActive = true
        let fillW = card.widthAnchor.constraint(equalTo: widthAnchor, constant: -32)
        fillW.priority = .defaultHigh
        fillW.isActive = true

        addSubview(placeholder)
        placeholder.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            placeholder.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 14),
            placeholder.topAnchor.constraint(equalTo: card.topAnchor, constant: 12),
            placeholder.trailingAnchor.constraint(lessThanOrEqualTo: card.trailingAnchor, constant: -16),
        ])

        // Controls.
        add.symbol = "plus"; add.style = .circle
        add.toolTip = "Add files or run commands"; add.setAccessibilityLabel("Add files or run commands")
        add.onPress = { [weak self] in self?.pickFiles() }
        mic.style = .icon
        mic.toolTip = "Dictate a message"; mic.setAccessibilityLabel("Dictate a message")
        mic.onPress = { [weak self] in self?.toggleVoice() }
        sendBtn.onPress = { [weak self] in
            guard let self else { return }
            self.running ? self.onStop() : self.submit()
        }
        sendBtn.toolTip = "Send (Return)"
        sendBtn.setAccessibilityLabel("Send message")

        modelChip.items = []; modelChip.onSelect = { [weak self] m in self?.modelPicked(m) }
        modelChip.setAccessibilityLabel("Model")
        profileChip.setAccessibilityLabel("Agent profile")
        profileChip.onSelect = { [weak self] p in self?.profilePicked(p) }
        autonomyChip.items = Autonomy.allCases.map(\.label)
        autonomyChip.selected = Settings.shared.autonomy.label
        autonomyChip.setAccessibilityLabel("Tool permissions")
        autonomyChip.widthAnchor.constraint(lessThanOrEqualToConstant: 220).isActive = true
        autonomyChip.onSelect = { [weak self] label in
            guard let a = Autonomy.allCases.first(where: { $0.label == label }) else { return }
            Settings.shared.autonomy = a
            self?.autonomyChip.selected = a.label
            self?.onAutonomyChange(a)
        }
        showModelStatus("Connect to load models")

        // Drop on the whole card, not just the editor.
        card.registerForDraggedTypes([.fileURL])
        card.onDropURLs = { [weak self] urls in self?.attach(urls) }
        textView.focusRingType = .none
        NotificationCenter.default.addObserver(self, selector: #selector(editorFocused),
                                              name: NSText.didBeginEditingNotification, object: textView)
        NotificationCenter.default.addObserver(self, selector: #selector(editorBlurred),
                                              name: NSText.didEndEditingNotification, object: textView)

        speech.onPartial = { [weak self] text in
            guard let self else { return }
            let token = self.speechToken
            guard self.speech.state == .recording else { return }
            let base = self.speechBase
            let separator = base.isEmpty || base.hasSuffix(" ") || base.hasSuffix("\n") ? "" : " "
            guard self.speechToken == token else { return }
            self.textView.string = base + separator + text
            self.updateEditor()
        }
        speech.onState = { [weak self] state in
            DispatchQueue.main.async {
                guard let self else { return }
                self.mic.tint = [.recording, .denied, .unavailable].contains(state) ? T.errorPrimary : nil
                let feedback: (String, String)
                switch state {
                case .denied:
                    feedback = ("Dictation unavailable: access denied", "Dictation access denied")
                case .unavailable:
                    feedback = ("Dictation unavailable", "Dictation unavailable")
                case .recording:
                    feedback = ("Stop dictation", "Stop dictation")
                case .starting:
                    feedback = ("Starting dictation…", "Starting dictation")
                case .idle:
                    feedback = ("Dictate a message", "Dictate a message")
                }
                self.mic.toolTip = feedback.0
                self.mic.setAccessibilityLabel(feedback.1)
                self.mic.needsDisplay = true
            }
        }
        updateEditor()
    }
    required init?(coder: NSCoder) { fatalError() }

    private var heroMinHeight: CGFloat { heroMode ? 44 : 36 }
    private var editorMaxHeight: CGFloat { 336 }

    // MARK: models

    func showModelStatus(_ title: String) {
        selectedModel = nil
        modelChip.items = []
        modelChip.statusText = title
        modelChip.enabled = false
    }
    func setModels(_ models: [String], preferred: String) {
        modelChip.enabled = true
        modelChip.statusText = nil
        modelChip.items = models
        if models.contains(preferred) { modelChip.selected = preferred }
        else { modelChip.selected = models.first }
        selectedModel = modelChip.selected
    }
    private func modelPicked(_ m: String) {
        selectedModel = m
        onModelChange(m)
    }
    func setProfiles(_ ids: [String], preferred: String) {
        profileChip.enabled = true
        profileChip.statusText = nil
        profileChip.items = ids
        profileChip.selected = ids.contains(preferred) ? preferred : ids.first
        selectedProfile = profileChip.selected ?? "standard"
    }
    private func profilePicked(_ p: String) {
        selectedProfile = p
        onProfileChange(p)
    }

    // MARK: state

    func setRunning(_ value: Bool) {
        running = value
        if !value { sending = false }
        sendBtn.mode = value ? .stop : (sending ? .sending : .send)
        sendBtn.setAccessibilityLabel(value ? "Stop" : "Send message")
        sendBtn.toolTip = value ? "Stop" : "Send (Return)"
    }
    @objc private func editorFocused() { card.stroke = T.accent }
    @objc private func editorBlurred() { card.stroke = T.borderL2 }

    var hasDraft: Bool { !textView.string.isEmpty || !attachments.isEmpty || pendingAttachments > 0 }
    func setDraftIfEmpty(_ text: String) { if !hasDraft { setDraft(text) } }
    func snapshotDraft() -> (String, [Attachment]) { (textView.string, attachments) }
    func restoreDraft(_ draft: (String, [Attachment])) {
        attachmentGeneration += 1
        attachmentTasks.values.forEach { $0.cancel() }
        attachmentTasks.removeAll()
        pendingAttachments = 0
        textView.string = draft.0; attachments = draft.1
        rebuildAttachments(); updateEditor()
    }
    /// Put the caret in the editor (after Branch / Rewind / Regenerate the
    /// next move is typing; a transcript reload otherwise strands focus).
    func focusEditor() {
        textView.window?.makeFirstResponder(textView)
    }
    func setDraft(_ text: String) {
        textView.string = text
        updateEditor()
        textView.window?.makeFirstResponder(textView)
        let end = (text as NSString).length
        textView.setSelectedRange(NSRange(location: end, length: 0))
    }

    // MARK: attachments

    private func submit() {
        guard !running, pendingAttachments == 0 else { return }
        let text = textView.string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty || !attachments.isEmpty else { return }
        guard onSend(text, attachments) else { return }
        sending = true
        if !running { sendBtn.mode = .sending }
        textView.string = ""; attachments = []; rebuildAttachments(); updateEditor()
    }
    private func pickFiles() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true; panel.canChooseDirectories = false; panel.allowsMultipleSelection = true
        if panel.runModal() == .OK { attach(panel.urls) }
    }
    private func attach(_ urls: [URL]) {
        guard !urls.isEmpty else { return }
        let generation = attachmentGeneration
        let batch = UUID()
        pendingAttachments += urls.count
        rebuildAttachments(); updateEditor()
        attachmentTasks[batch] = Task { [weak self] in
            let extracted = await Extract.attachments(for: urls)
            await MainActor.run { [weak self] in
                guard let self else { return }
                self.attachmentTasks.removeValue(forKey: batch)
                guard self.attachmentGeneration == generation else { return }
                self.pendingAttachments = max(0, self.pendingAttachments - urls.count)
                self.attachments.append(contentsOf: extracted)
                self.rebuildAttachments(); self.updateEditor()
            }
        }
    }
    private func rebuildAttachments() {
        attachStrip.arrangedSubviews.forEach { attachStrip.removeArrangedSubview($0); $0.removeFromSuperview() }
        attachStrip.isHidden = attachments.isEmpty && pendingAttachments == 0
        // A hidden strip must not leave its stack spacing behind in the card.
        if let inner = attachStrip.superview as? NSStackView {
            inner.setCustomSpacing(attachStrip.isHidden ? 0 : 12, after: attachStrip)
        }
        if pendingAttachments > 0 {
            attachStrip.addArrangedSubview(T.label("Reading \(pendingAttachments) file\(pendingAttachments == 1 ? "" : "s")…",
                                                     T.ui(12), T.labelSecondary))
        }
        for (i, a) in attachments.enumerated() {
            // Official attachment chip: 24px, hairline, radius 8, icon + name.
            let chip = Surface(T.bgBase, radius: 8, stroke: T.borderL1)
            chip.translatesAutoresizingMaskIntoConstraints = false
            let icon = T.icon("doc", size: 12, color: T.labelTertiary)
            let name = T.label(a.name, T.ui(12), T.labelPrimaryDim)
            name.lineBreakMode = .byTruncatingMiddle
            let rm = ActionButton(symbol: "xmark", style: .icon) { [weak self] in
                guard let self, self.attachments.indices.contains(i) else { return }
                self.attachments.remove(at: i); self.rebuildAttachments(); self.updateEditor()
            }
            rm.cornerRadius = 6
            rm.setAccessibilityLabel("Remove attachment")
            let row = horizontal([icon, name, rm], spacing: 4)
            row.edgeInsets = NSEdgeInsets(top: 0, left: 6, bottom: 0, right: 4)
            chip.addSubview(row); row.pin(to: chip)
            NSLayoutConstraint.activate([
                chip.heightAnchor.constraint(equalToConstant: 24),
                name.widthAnchor.constraint(lessThanOrEqualToConstant: 160),
            ])
            attachStrip.addArrangedSubview(chip)
        }
    }

    private func updateEditor() {
        placeholder.isHidden = !textView.string.isEmpty
        sendBtn.isEnabled = running || (pendingAttachments == 0 && (!textView.string.isEmpty || !attachments.isEmpty))
        // Measure the glyphs, not the frame: usedRect follows the text view's
        // current height and leaves a tall band of dead space in the card.
        var used: CGFloat = 0
        if let lm = textView.layoutManager, let tc = textView.textContainer {
            lm.ensureLayout(for: tc)
            used = lm.numberOfGlyphs > 0
                ? lm.boundingRect(forGlyphRange: NSRange(location: 0, length: lm.numberOfGlyphs), in: tc).height
                : (lm.extraLineFragmentRect.height > 0 ? lm.extraLineFragmentRect.height : 17)
        }
        let minH = heroMinHeight
        let target = min(editorMaxHeight, max(minH, ceil(used) + 12))
        if abs(editorHeight.constant - target) > 0.5 { editorHeight.constant = target }
    }
    private var lastLayoutWidth: CGFloat = 0
    override func layout() {
        super.layout()
        if abs(bounds.width - lastLayoutWidth) > 0.5 { lastLayoutWidth = bounds.width; updateEditor() }
    }
    func textDidChange(_ notification: Notification) { updateEditor() }
    private func toggleVoice() {
        if speech.state == .recording || speech.state == .starting { speechToken += 1; speech.stop() }
        else { speechToken += 1; speechBase = textView.string; speech.start() }
    }
}
