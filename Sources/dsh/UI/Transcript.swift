import AppKit

/// One message in the transcript. Users get the official right-aligned bubble; the agent
/// gets a reading column with reasoning disclosure, compact tool-step rows, markdown,
/// and code blocks on the official code-block surface.
final class MessageView: View {
    let messageID: UUID
    let role: Role
    private var text = ""
    private var reasoning = ""
    private let column = NSStackView()
    private let body = NSStackView()
    private let steps = NSStackView()
    private var toolRows: [UUID: StepView] = [:]
    private var reasoningSection: NSStackView?
    private var reasoningLabel: WrappingLabel?
    private var copyButton: ActionButton?
    private var renderTimer: Timer?
    private var reasoningTimer: Timer?
    private var streaming = false
    private struct ContentBlock {
        var isCode: Bool
        var language: String
        var text: String
    }
    /// Rendered block views keyed by (index, source text): streaming only
    /// grows the tail block, so earlier blocks are reused instead of
    /// rebuilding every code block every 45ms.
    private var blockCache: [(key: String, view: NSView)] = []
    private let loader = TurnLoader()

    init(message: Message, live: Bool = false) {
        messageID = message.id
        role = message.role; text = message.content; reasoning = message.reasoning
        streaming = live && role == .assistant
        super.init(frame: .zero)

        column.orientation = .vertical; column.alignment = .leading; column.spacing = 10
        column.edgeInsets = NSEdgeInsets(top: 2, left: 0, bottom: 2, right: 0)
        addSubview(column); column.pin(to: self)

        if role == .user {
            renderUser()
        } else {
            // Assistant: compact mark + name header, then reasoning/steps/body.
            let mark = BrandMarkView.fish(width: 18)
            let name = T.label("DeepSeek Harness", T.ui(13, .medium), T.labelSecondary)
            let copy = ActionButton(symbol: "doc.on.doc", style: .icon) { [weak self] in
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(self?.text ?? "", forType: .string)
            }
            copy.tint = T.labelTertiary; copy.setAccessibilityLabel("Copy response"); copy.toolTip = "Copy"
            copy.isHidden = true
            copyButton = copy
            let header = horizontal([mark, name, NSView(), copy], spacing: 8)
            header.alignment = .centerY
            copyWidthFix(copy)
            column.addArrangedSubview(header)
            header.widthAnchor.constraint(equalTo: column.widthAnchor).isActive = true

            body.orientation = .vertical; body.alignment = .leading; body.spacing = 10
            steps.orientation = .vertical; steps.alignment = .leading; steps.spacing = 2
            column.addArrangedSubview(body); column.addArrangedSubview(steps)
            loader.isHidden = !streaming || !text.isEmpty
            column.addArrangedSubview(loader)
            [body, steps, loader].forEach { $0.widthAnchor.constraint(equalTo: column.widthAnchor).isActive = true }
        }
        render()
        if !reasoning.isEmpty { renderReasoning(in: column) }
        message.steps.forEach { addStep($0) }
        if streaming && text.isEmpty { loader.isHidden = false }
    }
    required init?(coder: NSCoder) { fatalError() }

    // MARK: turn actions (Branch / Rewind / Regenerate)

    /// Actions for the last message of a completed turn. Nil removes them.
    struct TurnActions {
        var branch: () -> Void
        var rewind: (() -> Void)?     // earlier turns only (on the latest it is a no-op)
        var regenerate: (() -> Void)? // latest turn only
        var alwaysVisible: Bool       // latest turn: shown; earlier turns: on hover
    }
    private var actionsRow: NSStackView?
    private var actionsAlwaysVisible = false
    private var actionsTracking: NSTrackingArea?

    func setTurnActions(_ actions: TurnActions?) {
        actionsRow?.removeFromSuperview(); actionsRow = nil
        guard let actions, role == .assistant else { return }
        func action(_ symbol: String, _ label: String, _ run: @escaping () -> Void) -> ActionButton {
            let b = ActionButton(symbol: symbol, style: .icon, action: run)
            b.setFixedSize(26)
            b.tint = T.labelTertiary
            b.toolTip = label
            b.setAccessibilityLabel(label)
            return b
        }
        var buttons = [action("arrow.triangle.branch", "Branch into a new conversation", actions.branch)]
        if let rewind = actions.rewind {
            buttons.append(action("arrow.uturn.backward", "Rewind to here", rewind))
        }
        if let regenerate = actions.regenerate {
            buttons.append(action("arrow.clockwise", "Regenerate response", regenerate))
        }
        let row = horizontal(buttons, spacing: 2)
        row.setAccessibilityElement(false) // the buttons themselves are the controls
        column.addArrangedSubview(row)
        actionsRow = row
        actionsAlwaysVisible = actions.alwaysVisible
        // Fade, not hide: the row keeps its space, so hovering never shifts
        // the transcript, and VoiceOver always reaches the buttons.
        row.alphaValue = actions.alwaysVisible ? 1 : 0
        updateTrackingAreas()
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let t = actionsTracking { removeTrackingArea(t); actionsTracking = nil }
        guard actionsRow != nil, !actionsAlwaysVisible else { return }
        let t = NSTrackingArea(rect: .zero, options: [.inVisibleRect, .activeInKeyWindow, .mouseEnteredAndExited],
                               owner: self, userInfo: nil)
        addTrackingArea(t); actionsTracking = t
    }
    override func mouseEntered(with event: NSEvent) { revealActions(true) }
    override func mouseExited(with event: NSEvent) { revealActions(false) }
    private func revealActions(_ on: Bool) {
        guard let row = actionsRow, !actionsAlwaysVisible else { return }
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? 0 : 0.15
            row.animator().alphaValue = on ? 1 : 0
        }
    }

    /// The copy affordance stays quiet until the message has content.
    private func copyWidthFix(_ copy: ActionButton) {
        copy.setFixedSize(24)
    }

    // MARK: - streaming

    func appendText(_ delta: String) {
        text += delta
        if !text.isEmpty { loader.isHidden = true }
        guard renderTimer == nil else { return }
        renderTimer = Timer.scheduledTimer(withTimeInterval: 0.045, repeats: false) { [weak self] _ in
            self?.renderTimer = nil; self?.render()
        }
    }
    func finish() {
        renderTimer?.invalidate(); renderTimer = nil
        reasoningTimer?.invalidate(); reasoningTimer = nil
        streaming = false; loader.isHidden = true; render()
        if !reasoning.isEmpty { renderReasoning(in: column) }
    }
    func appendReasoning(_ delta: String) {
        reasoning += delta
        guard reasoningTimer == nil else { return }
        reasoningTimer = Timer.scheduledTimer(withTimeInterval: 0.045, repeats: false) { [weak self] _ in
            guard let self else { return }
            self.reasoningTimer = nil
            self.renderReasoning(in: self.column)
        }
    }

    // MARK: - user bubble

    private func renderUser() {
        body.orientation = .vertical; body.alignment = .leading; body.spacing = 10
        steps.orientation = .vertical; steps.alignment = .leading; steps.spacing = 2
        let bubble = UserBubble(text: text)
        let row = NSView()
        row.addSubview(bubble)
        bubble.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            bubble.topAnchor.constraint(equalTo: row.topAnchor),
            bubble.bottomAnchor.constraint(equalTo: row.bottomAnchor),
            bubble.trailingAnchor.constraint(equalTo: row.trailingAnchor),
            bubble.leadingAnchor.constraint(greaterThanOrEqualTo: row.leadingAnchor),
        ])
        column.addArrangedSubview(row)
        row.widthAnchor.constraint(equalTo: column.widthAnchor).isActive = true
        column.addArrangedSubview(body); column.addArrangedSubview(steps)
        [body, steps].forEach { $0.widthAnchor.constraint(equalTo: column.widthAnchor).isActive = true }
    }

    // MARK: - reasoning disclosure

    private func renderReasoning(in column: NSStackView) {
        if reasoningSection == nil {
            let header = DisclosureHeader()
            header.icon = "sparkles"; header.title = "Thinking"
            header.tint = T.labelTertiary
            header.onToggle = { [weak self, weak header] in
                guard let self else { return }
                let field = self.reasoningLabel
                let show = field?.isHidden ?? true
                field?.isHidden = !show
                if show { field?.stringValue = self.reasoning }
                header?.expanded = show
            }
            let field = WrappingLabel()
            field.font = T.ui(13); field.textColor = T.labelSecondary; field.isHidden = true
            let section = vertical([header, field], spacing: 6)
            column.insertArrangedSubview(section, at: min(1, column.arrangedSubviews.count))
            section.widthAnchor.constraint(equalTo: column.widthAnchor).isActive = true
            field.widthAnchor.constraint(equalTo: section.widthAnchor).isActive = true
            reasoningSection = section; reasoningLabel = field
        }
        if reasoningLabel?.isHidden == false { reasoningLabel?.stringValue = reasoning }
    }

    // MARK: - body

    private func render() {
        guard role != .user else { return }
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            copyButton?.isHidden = true
            body.arrangedSubviews.forEach { body.removeArrangedSubview($0); $0.removeFromSuperview() }
            blockCache.removeAll()
            return
        }
        let blocks = Self.contentBlocks(text)
        if blocks.count == 1, !blocks[0].isCode, body.arrangedSubviews.count == 1,
           let label = body.arrangedSubviews.first as? WrappingLabel {
            copyButton?.isHidden = false
            label.attributedStringValue = MD.render(blocks[0].text.trimmingCharacters(in: .newlines), fontSize: 14)
            return
        }
        copyButton?.isHidden = false
        var arranged: [NSView] = []
        var cache: [(key: String, view: NSView)] = []
        for (i, block) in blocks.enumerated() where !block.text.isEmpty || block.isCode {
            // Cheap key: position + kind + length + hash. The full block
            // text made every 45ms render tick copy every code block.
            let key = "\(i)\u{0}\(block.isCode)\u{0}\(block.language)\u{0}\(block.text.count)\u{0}\(block.text.hashValue)"
            if let hit = blockCache.first(where: { $0.key == key }) {
                arranged.append(hit.view); cache.append(hit)
            } else {
                let view = Self.blockView(block)
                arranged.append(view); cache.append((key, view))
            }
        }
        // Only touch the stack when membership actually changed.
        if arranged.count != body.arrangedSubviews.count
            || zip(arranged, body.arrangedSubviews).contains(where: { $0 !== $1 }) {
            body.arrangedSubviews.forEach { body.removeArrangedSubview($0); $0.removeFromSuperview() }
            for view in arranged {
                body.addArrangedSubview(view)
                view.widthAnchor.constraint(equalTo: body.widthAnchor).isActive = true
            }
        }
        blockCache = cache
    }

    private static func blockView(_ block: ContentBlock) -> NSView {
        if !block.isCode {
            let label = WrappingLabel()
            label.attributedStringValue = MD.render(block.text.trimmingCharacters(in: .newlines), fontSize: 14)
            return label
        } else {
            return CodeBlockView(language: block.language, code: block.text)
        }
    }

    private static func contentBlocks(_ source: String) -> [ContentBlock] {
        var blocks: [ContentBlock] = []
        var prose = "", code = ""
        var fence: (character: Character, length: Int, language: String)?
        let lines = source.components(separatedBy: "\n")
        for (index, line) in lines.enumerated() {
            let newline = index < lines.count - 1 ? "\n" : ""
            if let current = fence {
                let leading = line.prefix(while: { $0 == " " }).count
                let rest = line.dropFirst(leading)
                let markerCount = rest.prefix { $0 == current.character }.count
                if leading <= 3 && markerCount >= current.length
                    && String(rest.dropFirst(markerCount)).trimmingCharacters(in: .whitespaces).isEmpty {
                    blocks.append(ContentBlock(isCode: true, language: current.language, text: code))
                    code = ""; fence = nil
                } else {
                    code += line + newline
                }
                continue
            }
            let leading = line.prefix(while: { $0 == " " }).count
            let rest = line.dropFirst(leading)
            guard leading <= 3, let marker = rest.first, marker == "`" || marker == "~" else {
                prose += line + newline
                continue
            }
            let count = rest.prefix { $0 == marker }.count
            let info = String(rest.dropFirst(count)).trimmingCharacters(in: .whitespaces)
            guard count >= 3, marker != "`" || !info.contains("`") else {
                prose += line + newline
                continue
            }
            if !prose.isEmpty { blocks.append(ContentBlock(isCode: false, language: "", text: prose)); prose = "" }
            fence = (marker, count, info)
        }
        if let fence {
            blocks.append(ContentBlock(isCode: true, language: fence.language, text: code))
        } else if !prose.isEmpty {
            blocks.append(ContentBlock(isCode: false, language: "", text: prose))
        }
        return blocks
    }

    // MARK: - steps

    func addStep(_ step: Step) {
        let row = StepView(step)
        toolRows[step.id] = row; steps.addArrangedSubview(row)
        row.widthAnchor.constraint(equalTo: steps.widthAnchor).isActive = true
    }
    func updateStep(_ step: Step) { toolRows[step.id]?.update(step) }
}

/// The official user bubble: specific-bubble fill, 20px radius, 10/16 padding,
/// max-width min(525px, 82% of column), hugs short text.
final class UserBubble: Surface {
    private let label = WrappingLabel()
    private let text: String
    private var widthCap: NSLayoutConstraint!

    init(text: String) {
        self.text = text
        super.init(T.bubble, radius: 14, stroke: T.borderL2)
        elevation = .soft
        label.font = T.ui(14); label.textColor = T.labelPrimary
        label.stringValue = text
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        addSubview(label)
        label.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -16),
            label.topAnchor.constraint(equalTo: topAnchor, constant: 10),
            label.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -10),
        ])
        widthCap = widthAnchor.constraint(equalToConstant: 240)
        widthCap.priority = .defaultHigh
        widthCap.isActive = true
    }
    required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        let colW = superview?.bounds.width ?? bounds.width
        guard colW > 120 else { return }
        let cap = min(525, colW * 0.82)
        let natural = (text as NSString).boundingRect(
            with: NSSize(width: CGFloat.greatestFiniteMagnitude, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            attributes: [.font: T.ui(14)]).size
        let w = (natural.width + 32 <= cap) ? ceil(natural.width) + 32 : cap
        if abs(widthCap.constant - w) > 1 {
            widthCap.constant = w
            needsLayout = true
        }
    }
}

/// Compact disclosure header used by reasoning and tool-step rows:
/// 16px glyph, 13px title, optional meta, trailing chevron, hover wash, ~26px tall.
final class DisclosureHeader: View {
    var icon = "" { didSet { refreshIcon() } }
    var title = "" { didSet { titleLabel.stringValue = title; setAccessibilityLabel(title.isEmpty ? "Disclosure" : title) } }
    var meta = "" { didSet { metaLabel.stringValue = meta; metaLabel.isHidden = meta.isEmpty } }
    var tint: NSColor = T.labelSecondary { didSet { titleLabel.textColor = tint; refreshIcon() } }
    var expanded = false { didSet { chevron.image = Self.chevron(expanded) ; needsDisplay = true } }
    var onToggle: () -> Void = {}
    /// Optional trailing control (e.g. "Review"), shown before the chevron.
    var accessory: NSView? {
        didSet {
            oldValue?.removeFromSuperview()
            if let accessory { row.insertArrangedSubview(accessory, at: row.arrangedSubviews.count - 1) }
        }
    }

    private let iconView = NSImageView()
    private let titleLabel = T.label("", T.ui(13), T.labelSecondary)
    private let metaLabel = T.label("", T.ui(12), T.labelCaption)
    private let chevron = NSImageView()
    private var hover = false
    private var tracking: NSTrackingArea?
    private var row: NSStackView!

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        metaLabel.isHidden = true
        heightAnchor.constraint(equalToConstant: 26).isActive = true
        iconView.symbolConfiguration = .init(pointSize: 14, weight: .medium)
        iconView.contentTintColor = T.labelSecondary
        iconView.widthAnchor.constraint(equalToConstant: 16).isActive = true
        iconView.heightAnchor.constraint(equalToConstant: 16).isActive = true
        chevron.symbolConfiguration = .init(pointSize: 10, weight: .semibold)
        chevron.contentTintColor = T.labelCaption
        chevron.image = Self.chevron(false)
        chevron.widthAnchor.constraint(equalToConstant: 12).isActive = true
        chevron.heightAnchor.constraint(equalToConstant: 12).isActive = true
        metaLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        row = horizontal([iconView, titleLabel, metaLabel, NSView(), chevron], spacing: 7)
        row.edgeInsets = NSEdgeInsets(top: 0, left: 4, bottom: 0, right: 6)
        addSubview(row)
        row.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            row.leadingAnchor.constraint(equalTo: leadingAnchor),
            row.trailingAnchor.constraint(equalTo: trailingAnchor),
            row.topAnchor.constraint(equalTo: topAnchor),
            row.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        let click = NSClickGestureRecognizer(target: self, action: #selector(toggled))
        addGestureRecognizer(click)
        // Keyboard + VoiceOver: this is a button, not just a click target.
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
    }
    required init?(coder: NSCoder) { fatalError() }

    override var acceptsFirstResponder: Bool { true }
    override func keyDown(with event: NSEvent) {
        if event.keyCode == 36 || event.keyCode == 49 { onToggle(); return } // Return / Space
        super.keyDown(with: event)
    }
    override func accessibilityPerformPress() -> Bool { onToggle(); return true }

    private static func chevron(_ down: Bool) -> NSImage? {
        NSImage(systemSymbolName: down ? "chevron.down" : "chevron.right",
                accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 10, weight: .semibold))
    }
    private func refreshIcon() {
        iconView.image = NSImage(systemSymbolName: icon, accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 14, weight: .medium))
        iconView.contentTintColor = tint
    }
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let t = tracking { removeTrackingArea(t) }
        tracking = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self)
        if let tracking { addTrackingArea(tracking) }
    }
    override func mouseEntered(with event: NSEvent) { hover = true; needsDisplay = true }
    override func mouseExited(with event: NSEvent) { hover = false; needsDisplay = true }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .pointingHand) }
    @objc private func toggled(_ gesture: NSClickGestureRecognizer) {
        // A click on the accessory (the Review button) is that button's,
        // not a request to expand the row as well.
        if let accessory, !accessory.isHidden,
           accessory.bounds.contains(gesture.location(in: accessory)) { return }
        window?.makeFirstResponder(self)
        onToggle()
    }
    override func draw(_ rect: NSRect) {
        if hover {
            let p = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 1), xRadius: 8, yRadius: 8)
            T.hoverBg.setFill(); p.fill()
        }
        if window?.firstResponder === self {
            T.accent.withAlphaComponent(0.7).setStroke()
            let ring = NSBezierPath(roundedRect: bounds.insetBy(dx: 1.5, dy: 1.5), xRadius: 8, yRadius: 8)
            ring.lineWidth = 2
            ring.stroke()
        }
    }
}

/// A collapsed one-line tool call that expands into its input and output.
final class StepView: View {
    private let header = DisclosureHeader()
    private let detail = StepDetailView()
    private var expanded = false
    private var hasDetail = false

    init(_ step: Step) {
        super.init(frame: .zero)
        let column = vertical([header, detail], spacing: 6)
        column.edgeInsets = NSEdgeInsets(top: 0, left: 0, bottom: 2, right: 0)
        addSubview(column); column.pin(to: self)
        [header, detail].forEach { $0.widthAnchor.constraint(equalTo: column.widthAnchor).isActive = true }
        expanded = step.expanded
        header.expanded = expanded
        header.onToggle = { [weak self] in self?.toggle() }
        update(step)
    }
    required init?(coder: NSCoder) { fatalError() }

    private func toggle() {
        expanded.toggle()
        header.expanded = expanded
        detail.isHidden = !expanded || !hasDetail
    }

    func update(_ step: Step) {
        let args = JSON.object(step.payload)
        let title = Self.stepTitle(name: step.name, args: args)
        header.title = String(title.replacingOccurrences(of: "\n", with: " ").prefix(90))
        // Bash titles are the command; its one-line description rides in the
        // tooltip (upstream renders it above the terminal card).
        header.toolTip = args.str("description") ?? title
        // The glyph names the tool for the life of the row; status rides on
        // the tint. Swapping to a checkmark on success erased read vs. edit.
        header.icon = step.status == .error || step.status == .denied ? "exclamationmark.circle" : T.toolIcon(step.name)
        // Status is never part of the title (upstream rule), so say it here
        // in words: the red tint alone would be color-only meaning.
        switch step.status {
        case .denied: header.meta = "Denied"
        case .error: header.meta = "Failed"
        default: header.meta = Self.durationText(step.durationMS)
        }
        let writesFile = (step.name == "write" || step.name == "edit") && step.status == .ok
        if writesFile, let path = args.str("file_path") {
            if header.accessory == nil {
                let review = ActionButton("Review", style: .plain) { [weak self] in
                    NSApp.sendAction(#selector(ReviewRouting.showReview(_:)), to: nil, from: ReviewRequest(path: path, origin: self))
                }
                review.font = T.ui(12, .medium); review.tint = T.accent
                review.toolTip = "Show this change in Review"
                review.setAccessibilityLabel("Review change to \((path as NSString).lastPathComponent)")
                header.accessory = review
            }
        } else {
            header.accessory = nil
        }
        let tint: NSColor
        switch step.status {
        case .error, .denied: tint = T.errorPrimary
        case .running, .pending, .waiting: tint = T.labelTertiary
        default: tint = T.labelSecondary
        }
        header.tint = tint
        hasDetail = !step.payload.isEmpty || !step.result.isEmpty
        detail.populate(input: step.payload, output: step.result, status: step.status)
        detail.isHidden = !(expanded && hasDetail)
        if step.status == .error && !expanded { expanded = true; header.expanded = true; detail.isHidden = false }
    }
}

extension StepView {
    /// Durations under 100 ms are noise in a transcript ("0.0s" read as a
    /// rounding bug); show milliseconds below a second, seconds above.
    static func durationText(_ ms: Int) -> String {
        switch ms {
        case ..<100: return ""
        case ..<1000: return "\(ms) ms"
        default: return String(format: "%.1fs", Double(ms) / 1000)
        }
    }

    /// Row title for a tool call, mirroring the official DeepSeek Harness
    /// presenters (each tool's `presentCall` in deepseek-ai/deepseek-harness:
    /// packages/fs/tool-fs, fs/tool-fs-search, web/tool-web, shell/*):
    /// an imperative verb plus what the call targets, the path exactly as the
    /// model passed it, and NO status: a call is named by what it does, the
    /// same while pending, after success, or on failure.
    static func stepTitle(name: String, args: [String: Any]) -> String {
        func within(_ path: String?) -> String { path.map { " in \($0)" } ?? "" }
        switch name {
        case "read":
            let path = args.str("file_path") ?? ""
            let offset = args.int("offset"), limit = args.int("limit")
            let window: String
            if let limit, limit > 0 { window = " (\(offset ?? 1) - \((offset ?? 1) + limit - 1))" }
            else if let offset { window = " (from line \(offset))" }
            else { window = "" }
            return "Read \(path)\(window)"
        case "write": return "Write \(args.str("file_path") ?? "")"
        case "edit": return "Edit \(args.str("file_path") ?? "")"
        case "bash": return args.str("command") ?? "bash"
        case "grep":
            let filter = args.str("glob").flatMap { $0.isEmpty ? nil : " (\($0))" } ?? ""
            return "Grep \(args.str("pattern") ?? "")\(within(args.str("path")))\(filter)"
        case "glob": return "Glob \(args.str("pattern") ?? "")\(within(args.str("path")))"
        case "web_fetch": return args.str("url") ?? "web_fetch"
        case "web_search": return args.str("query") ?? "web_search"
        default:
            // Upstream's fallback kind is "other": the tool's own name. Keep a
            // model-supplied description when there is one (subagents, plugins).
            return [name, args.str("description")].compactMap { $0 }.joined(separator: ": ")
        }
    }
}

/// Carries a Review request up the responder chain from a transcript row.
final class ReviewRequest: NSObject {
    let path: String
    weak var origin: NSView?
    init(path: String, origin: NSView?) { self.path = path; self.origin = origin }
}

/// Implemented by the window controller: opens the inspector on Review.
@objc protocol ReviewRouting {
    func showReview(_ sender: Any?)
}

/// Indented detail card for a tool step: mono 11/16 text on the code-block surface.
final class StepDetailView: Surface {
    private let stack = NSStackView()

    init() {
        super.init(T.codeBlock, radius: 10, stroke: T.borderL1c)
        stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 8
        stack.edgeInsets = NSEdgeInsets(top: 10, left: 12, bottom: 10, right: 12)
        addSubview(stack)
        stack.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        addStrokeOverlay()
        wantsLayer = true
        layer?.cornerRadius = 10
        layer?.masksToBounds = true
    }
    required init?(coder: NSCoder) { fatalError() }

    func populate(input: String, output: String, status: StepStatus) {
        stack.arrangedSubviews.forEach { stack.removeArrangedSubview($0); $0.removeFromSuperview() }
        if !input.isEmpty {
            stack.addArrangedSubview(section("INPUT", input, status: status))
        }
        if !output.isEmpty {
            stack.addArrangedSubview(section("OUTPUT", output, status: status))
        }
        if input.isEmpty && output.isEmpty {
            stack.addArrangedSubview(section("DETAIL", "(no details)", status: status))
        }
    }

    private func section(_ title: String, _ body: String, status: StepStatus) -> NSView {
        let head = T.label(title, T.mono(10, .semibold), T.labelCaption)
        let field = WrappingLabel()
        field.font = T.mono(11); field.textColor = status == .error ? T.errorPrimary : T.labelSecondary
        let clipped = body.count > 6000 ? String(body.prefix(6000)) + "\n… (truncated)" : body
        field.stringValue = clipped
        field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let col = vertical([head, field], spacing: 4)
        col.alignment = .leading
        head.widthAnchor.constraint(equalTo: col.widthAnchor).isActive = true
        field.widthAnchor.constraint(equalTo: col.widthAnchor).isActive = true
        return col
    }
}

/// Official code block: banner row (language + copy) on the banner wash,
/// code on the code-block surface, 12px radius, hairline stroke.
final class CodeBlockView: Surface {
    init(language: String, code: String) {
        super.init(T.codeBlock, radius: 12, stroke: T.borderL1c)
        wantsLayer = true
        layer?.cornerRadius = 12
        layer?.masksToBounds = true

        // Banner strip — full-bleed at the top of the card.
        let banner = TintedView(T.codeBlockBanner)
        let lang = T.label(language.isEmpty ? "Code" : language, T.mono(11, .medium), T.labelTertiary)
        lang.alignment = .left
        let copy = ActionButton(symbol: "doc.on.doc", style: .icon) {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(code, forType: .string)
        }
        copy.tint = T.labelTertiary; copy.setAccessibilityLabel("Copy code"); copy.toolTip = "Copy"
        copy.setFixedSize(24)
        let bannerRow = horizontal([lang, NSView(), copy], spacing: 8)
        bannerRow.edgeInsets = NSEdgeInsets(top: 0, left: 12, bottom: 0, right: 8)
        banner.addSubview(bannerRow)
        bannerRow.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            bannerRow.leadingAnchor.constraint(equalTo: banner.leadingAnchor),
            bannerRow.trailingAnchor.constraint(equalTo: banner.trailingAnchor),
            bannerRow.topAnchor.constraint(equalTo: banner.topAnchor),
            bannerRow.bottomAnchor.constraint(equalTo: banner.bottomAnchor),
            banner.heightAnchor.constraint(equalToConstant: 34),
        ])

        let codeLabel = WrappingLabel()
        codeLabel.font = T.mono(11.5); codeLabel.textColor = T.text
        codeLabel.stringValue = code.trimmingCharacters(in: .newlines)
        codeLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let codeWrap = NSView()
        codeWrap.addSubview(codeLabel)
        codeLabel.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            codeLabel.leadingAnchor.constraint(equalTo: codeWrap.leadingAnchor, constant: 12),
            codeLabel.trailingAnchor.constraint(equalTo: codeWrap.trailingAnchor, constant: -12),
            codeLabel.topAnchor.constraint(equalTo: codeWrap.topAnchor, constant: 8),
            codeLabel.bottomAnchor.constraint(equalTo: codeWrap.bottomAnchor, constant: -10),
        ])

        [banner, codeWrap].forEach {
            addSubview($0)
            $0.translatesAutoresizingMaskIntoConstraints = false
        }
        NSLayoutConstraint.activate([
            banner.leadingAnchor.constraint(equalTo: leadingAnchor),
            banner.trailingAnchor.constraint(equalTo: trailingAnchor),
            banner.topAnchor.constraint(equalTo: topAnchor),
            codeWrap.leadingAnchor.constraint(equalTo: leadingAnchor),
            codeWrap.trailingAnchor.constraint(equalTo: trailingAnchor),
            codeWrap.topAnchor.constraint(equalTo: banner.bottomAnchor),
            codeWrap.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        addStrokeOverlay()
    }
    required init?(coder: NSCoder) { fatalError() }
}

/// Three-dot turn loader shown while the assistant is thinking.
final class TurnLoader: View {
    private var started = false
    override init(frame: NSRect) {
        super.init(frame: frame)
        heightAnchor.constraint(equalToConstant: 22).isActive = true
    }
    required init?(coder: NSCoder) { fatalError() }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard window != nil, !started else { return }
        started = true
        let stack = horizontal([], spacing: 5)
        stack.alignment = .centerY
        stack.edgeInsets = NSEdgeInsets(top: 0, left: 4, bottom: 0, right: 0)
        let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        for i in 0..<3 {
            let dot = TintedView(T.accent, radius: 3)
            dot.widthAnchor.constraint(equalToConstant: 6).isActive = true
            dot.heightAnchor.constraint(equalToConstant: 6).isActive = true
            if !reduceMotion {
                let anim = CABasicAnimation(keyPath: "opacity")
                anim.fromValue = 0.25; anim.toValue = 1
                anim.duration = 0.9; anim.autoreverses = true; anim.repeatCount = .infinity
                anim.beginTime = CACurrentMediaTime() + Double(i) * 0.18
                dot.layer?.add(anim, forKey: "pulse")
            }
            stack.addArrangedSubview(dot)
        }
        addSubview(stack)
        stack.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }
}

/// Inline approval request for a gated tool call: warn strip on top,
/// detail card, Reject/Allow actions, 20px radius.
final class ApprovalView: Surface {
    var onDone: (() -> Void)?
    private var answered = false
    private weak var allowButton: ActionButton?
    private weak var rejectButton: ActionButton?

    init(tool: String, summary: String, respond: @escaping (Bool) -> Void) {
        super.init(T.bgLayer2, radius: 12, stroke: T.borderL2)
        wantsLayer = true
        layer?.cornerRadius = 12
        layer?.masksToBounds = true

        // Warn-tinted header strip.
        let strip = TintedView(T.warnTertiary)
        let shield = T.icon("exclamationmark.shield", size: 14, color: T.warnLabel)
        let headLabel = T.label("Approval required", T.ui(13, .medium), T.warnLabel)
        let toolLabel = T.label(tool, T.ui(12), T.labelTertiary)
        let stripRow = horizontal([shield, headLabel, NSView(), toolLabel], spacing: 7)
        stripRow.edgeInsets = NSEdgeInsets(top: 0, left: 14, bottom: 0, right: 14)
        strip.addSubview(stripRow)
        stripRow.translatesAutoresizingMaskIntoConstraints = false
        // The strip must be in this view's hierarchy before its constraints
        // to `leadingAnchor` etc. are activated: activating a constraint
        // whose views share no common ancestor throws and aborts the app.
        addSubview(strip)
        strip.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            stripRow.leadingAnchor.constraint(equalTo: strip.leadingAnchor),
            stripRow.trailingAnchor.constraint(equalTo: strip.trailingAnchor),
            stripRow.topAnchor.constraint(equalTo: strip.topAnchor),
            stripRow.bottomAnchor.constraint(equalTo: strip.bottomAnchor),
            strip.heightAnchor.constraint(equalToConstant: 38),
            strip.leadingAnchor.constraint(equalTo: leadingAnchor),
            strip.trailingAnchor.constraint(equalTo: trailingAnchor),
            strip.topAnchor.constraint(equalTo: topAnchor),
        ])

        let detail = Surface(T.codeBlock, radius: 10, stroke: T.borderL1c)
        let field = WrappingLabel()
        field.font = T.mono(11); field.textColor = T.labelSecondary
        field.stringValue = summary.count > 4000 ? String(summary.prefix(4000)) + "\n…" : summary
        detail.addSubview(field)
        field.pin(to: detail, inset: 10)

        let reject = ActionButton("Reject", style: .filled)
        let allow = ActionButton("Allow", symbol: "checkmark", style: .primary)
        allowButton = allow
        rejectButton = reject
        let resolve: (Bool) -> Void = { [weak self] ok in
            guard let self, !self.answered else { return }
            self.answered = true
            self.disableButtons()
            respond(ok)
            self.onDone?()
        }
        allow.onPress = { resolve(true) }; reject.onPress = { resolve(false) }
        let buttons = horizontal([NSView(), reject, allow], spacing: 8)

        [detail, buttons].forEach {
            addSubview($0)
            $0.translatesAutoresizingMaskIntoConstraints = false
        }
        NSLayoutConstraint.activate([
            detail.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14),
            detail.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -14),
            detail.topAnchor.constraint(equalTo: strip.bottomAnchor, constant: 12),
            buttons.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14),
            buttons.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -14),
            buttons.topAnchor.constraint(equalTo: detail.bottomAnchor, constant: 12),
            buttons.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -14),
        ])
        addStrokeOverlay()
    }
    required init?(coder: NSCoder) { fatalError() }

    func dismiss() {
        guard !answered else { return }
        answered = true
        disableButtons()
        onDone?()
    }

    private func disableButtons() {
        allowButton?.isEnabled = false
        rejectButton?.isEnabled = false
        allowButton?.onPress = {}
        rejectButton?.onPress = {}
    }
}
