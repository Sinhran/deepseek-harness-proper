import AppKit

/// Base view that repaints its own layer colors when the effective appearance changes.
class View: NSView {
    override var isFlipped: Bool { true }
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyColors()
    }
    /// Override to re-resolve dynamic colors into layer properties.
    func applyColors() { needsDisplay = true }
}

/// A rounded surface with an optional 0.5pt stroke and soft elevation.
class Surface: View {
    enum Elevation { case none, soft, panel }
    var fill: NSColor? { didSet { needsDisplay = true } }
    var stroke: NSColor? { didSet { needsDisplay = true } }
    var radius: CGFloat = 0 { didSet { needsDisplay = true } }
    var elevation: Elevation = .none { didSet { needsDisplay = true } }

    init(_ fill: NSColor? = nil, radius: CGFloat = 0, stroke: NSColor? = nil) {
        self.fill = fill; self.radius = radius; self.stroke = stroke
        super.init(frame: .zero)
    }
    required init?(coder: NSCoder) { fatalError() }

    override func draw(_ rect: NSRect) {
        let inset: CGFloat = stroke != nil || elevation != .none ? 0.25 : 0
        let path = NSBezierPath(roundedRect: bounds.insetBy(dx: inset, dy: inset),
                                xRadius: max(0, radius - inset), yRadius: max(0, radius - inset))
        switch elevation {
        case .none:
            break
        case .soft, .panel:
            NSGraphicsContext.saveGraphicsState()
            let shadow = NSShadow()
            shadow.shadowColor = NSColor.black.withAlphaComponent(elevation == .soft ? 0.03 : 0.05)
            shadow.shadowBlurRadius = elevation == .soft ? 16 : 12
            shadow.shadowOffset = NSSize(width: 0, height: -4)
            shadow.set()
            fill?.setFill(); path.fill()
            NSGraphicsContext.restoreGraphicsState()
        }
        if elevation == .none { fill?.setFill(); path.fill() }
        if let stroke {
            // Official elevation stroke: 0 0 0 .5px border-l4.
            stroke.setStroke()
            path.lineWidth = 0.5
            path.stroke()
        }
    }

    func addStrokeOverlay() {
        guard stroke != nil else { return }
        let overlay = SurfaceStrokeOverlay(surface: self)
        addSubview(overlay)
        overlay.pin(to: self)
    }
}

private final class SurfaceStrokeOverlay: View {
    weak var surface: Surface?
    init(surface: Surface) {
        self.surface = surface
        super.init(frame: .zero)
    }
    required init?(coder: NSCoder) { fatalError() }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func draw(_ rect: NSRect) {
        guard let surface, let stroke = surface.stroke else { return }
        let inset: CGFloat = 0.25
        let path = NSBezierPath(roundedRect: bounds.insetBy(dx: inset, dy: inset),
                                xRadius: max(0, surface.radius - inset),
                                yRadius: max(0, surface.radius - inset))
        stroke.setStroke()
        path.lineWidth = 0.5
        path.stroke()
    }
}

/// Flattened label view so a plain `NSView` can be used where a flipped container is needed.
final class FlippedView: NSView {
    override var isFlipped: Bool { true }
}

/// Plain view whose layer background tracks a dynamic color across appearance changes.
/// The color resolves in `updateLayer`, so it follows light/dark switches instead of
/// freezing the `cgColor` captured at creation time.
final class TintedView: View {
    var tint: NSColor { didSet { needsDisplay = true } }
    var cornerRadius: CGFloat = 0 { didSet { needsDisplay = true } }
    init(_ color: NSColor, radius: CGFloat = 0) {
        tint = color; cornerRadius = radius
        super.init(frame: .zero)
        wantsLayer = true
    }
    required init?(coder: NSCoder) { fatalError() }
    override func updateLayer() {
        layer?.backgroundColor = tint.cgColor
        layer?.cornerRadius = cornerRadius
    }
}

/// 0.5pt hairline divider that tracks a dynamic color across appearance changes.
final class HairlineView: View {
    var color: NSColor { didSet { needsDisplay = true } }
    init(_ color: NSColor) {
        self.color = color
        super.init(frame: .zero)
        wantsLayer = true
        heightAnchor.constraint(equalToConstant: 0.5).isActive = true
    }
    required init?(coder: NSCoder) { fatalError() }
    override func updateLayer() {
        layer?.backgroundColor = color.cgColor
    }
}

/// Uniform button matching the official primitives: quiet rows, 28px icon buttons,
/// monochrome primary capsules, blue info circles, hairline chips.
final class ActionButton: NSButton {
    enum Style {
        case plain    // quiet text button, hover wash, radius 8
        case row      // session/list row: 32h, radius 12, hover wash
        case nav      // panel row: 36h, radius 12, glyph + label
        case filled   // elevated chip: selector/elevated fill + .5 hairline, radius 12
        case cta      // "New Session": 38h, radius 12, .5 l3 border, elevated fill
        case primary  // monochrome ink capsule
        case info     // blue info fill (send/stop)
        case icon     // 28x28 icon button, radius 8
        case circle   // 28px selector-fill circle (composer add button)
        case tab      // dock tab: 30h, icon + 12px label, selected wash
        case iconTab  // icon-only dock tab: 34x30, pill highlight like .tab
        case danger   // outline button that goes danger on hover
    }
    var style: Style = .plain
    var symbol: String? { didSet { resyncAccessibilityLabel() } }
    var caption: String = ""
    var selected = false { didSet { needsDisplay = true } }
    var tint: NSColor? { didSet { needsDisplay = true } }
    /// Overrides the glyph color only (title keeps `tint`/style ink).
    var iconTint: NSColor? { didSet { needsDisplay = true } }
    var onPress: () -> Void = {}
    var onHoverChange: ((Bool) -> Void)?
    var cornerRadius: CGFloat? // override per-instance
    /// Width reserved at the trailing edge for an overlaid accessory (the
    /// sidebar's delete button), so the title truncates before it.
    var trailingInset: CGFloat = 0 { didSet { needsDisplay = true } }
    /// Small count drawn at the top-trailing corner (icon tabs). Empty hides it.
    var badge = "" { didSet { needsDisplay = true } }
    /// Act on the click that also activates the window. Titlebar controls
    /// behave this way on macOS (Finder's sidebar toggle); content stays off.
    var actsOnFirstClick = false
    /// Per-instance glyph box (pt). Nil keeps the style's size; the top row
    /// uses a larger glyph so its controls read at window-chrome scale.
    var iconBox: CGFloat? { didSet { needsDisplay = true } }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { actsOnFirstClick }
    private var hover = false

    /// Re-derive hover from the live pointer position. Tracking areas can
    /// miss mouseExited when content moves under a still pointer (scrolling,
    /// a list rebuild), which left rows stuck in their hover state.
    func syncHoverWithPointer() {
        guard let window, !isHiddenOrHasHiddenAncestor else { setHover(false); return }
        let p = convert(window.mouseLocationOutsideOfEventStream, from: nil)
        setHover(visibleRect.contains(p))
    }
    private func setHover(_ value: Bool) {
        guard hover != value else { return }
        hover = value; needsDisplay = true; onHoverChange?(value)
    }
    private var sizeConstraints: [NSLayoutConstraint] = []
    /// Last label we derived ourselves; an explicit setAccessibilityLabel
    /// is never overwritten by later title/symbol changes.
    private var derivedLabel = ""
    override var title: String { didSet { resyncAccessibilityLabel() } }
    private func resyncAccessibilityLabel() {
        let current = accessibilityLabel() ?? ""
        guard current.isEmpty || current == derivedLabel else { return }
        derivedLabel = title.isEmpty ? (symbol ?? "Button") : title
        setAccessibilityLabel(derivedLabel)
    }

    /// Replace the style's fixed size (e.g. 28px icon -> 24px) without
    /// stacking a conflicting constraint on top of it.
    func setFixedSize(_ s: CGFloat) {
        sizeConstraints.forEach { $0.isActive = false }
        sizeConstraints = [widthAnchor.constraint(equalToConstant: s), heightAnchor.constraint(equalToConstant: s)]
        NSLayoutConstraint.activate(sizeConstraints)
    }

    init(_ title: String = "", symbol: String? = nil, style: Style = .plain, action: @escaping () -> Void = {}) {
        self.symbol = symbol; self.style = style; self.onPress = action
        super.init(frame: .zero)
        self.title = title
        // NSButton.font defaults to 13pt, so `font ?? defaultFont` below would
        // never reach the per-style sizes (rows/nav 14, tabs 12 medium). Apply
        // the style's font explicitly; callers can still override it.
        font = defaultFont
        isBordered = false; target = self; self.action = #selector(pressed)
        resyncAccessibilityLabel()
        switch style {
        case .icon, .circle:
            sizeConstraints = [widthAnchor.constraint(equalToConstant: 28), heightAnchor.constraint(equalToConstant: 28)]
            NSLayoutConstraint.activate(sizeConstraints)
        case .row: heightAnchor.constraint(equalToConstant: 32).isActive = true
        case .nav: heightAnchor.constraint(equalToConstant: 36).isActive = true
        case .tab, .iconTab: heightAnchor.constraint(equalToConstant: 30).isActive = true
        case .filled: heightAnchor.constraint(equalToConstant: 30).isActive = true
        case .cta: heightAnchor.constraint(equalToConstant: 38).isActive = true
        case .primary, .info: heightAnchor.constraint(equalToConstant: 34).isActive = true
        case .plain, .danger: break
        }
    }
    required init?(coder: NSCoder) { fatalError() }
    @objc private func pressed() { onPress() }

    private var defaultFont: NSFont {
        switch style {
        case .row, .nav: return T.ui(14)
        case .tab, .iconTab: return T.ui(12, .medium)
        case .filled, .primary, .info, .cta: return T.ui(13, .medium)
        case .icon, .circle: return T.ui(13)
        case .plain, .danger: return T.ui(13)
        }
    }
    private var textColor: NSColor {
        if let tint { return tint }
        switch style {
        case .primary: return T.labelOnPrimary
        case .info: return T.rgb(0x16150F)
        case .icon, .circle, .tab, .iconTab: return labelSecondaryOrPrimary
        case .row, .nav, .cta, .filled, .plain, .danger: return T.labelPrimary
        }
    }
    private var labelSecondaryOrPrimary: NSColor { hover ? T.labelPrimary : T.labelSecondary }

    private var corner: CGFloat {
        if let cornerRadius { return cornerRadius }
        switch style {
        case .icon: return 8
        case .circle: return 999
        case .primary, .info: return 9
        case .tab, .iconTab: return 8
        case .row, .nav, .danger: return 8
        case .cta, .filled: return 9
        case .plain: return 8
        }
    }

    override var intrinsicContentSize: NSSize {
        let f = font ?? defaultFont
        let tw = title.isEmpty ? 0 : (title as NSString).size(withAttributes: [.font: f]).width
        let cw = caption.isEmpty ? 0 : (caption as NSString).size(withAttributes: [.font: T.ui(12)]).width
        let iconW: CGFloat = symbol == nil ? 0 : (title.isEmpty ? 0 : 16 + 8)
        switch style {
        case .icon: return NSSize(width: 28, height: 28)
        case .circle: return NSSize(width: 28, height: 28)
        case .tab: return NSSize(width: max(56, tw + iconW + 20), height: 30)
        case .iconTab: return NSSize(width: 34, height: 30)
        case .row, .nav: return NSSize(width: max(28, tw + iconW + 20 + (caption.isEmpty ? 0 : cw + 12)), height: style == .nav ? 36 : 32)
        case .cta: return NSSize(width: max(120, tw + iconW + 44), height: 38)
        case .filled, .primary, .info: return NSSize(width: max(30, tw + iconW + 22), height: style == .info ? 34 : 30)
        case .plain, .danger:
            return NSSize(width: max(24, tw + iconW + (caption.isEmpty ? 18 : cw + 22)),
                          height: 28)
        }
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.inVisibleRect, .activeAlways, .mouseEnteredAndExited],
                                      owner: self, userInfo: nil))
    }
    override func mouseEntered(with event: NSEvent) { setHover(true) }
    override func mouseExited(with event: NSEvent) { setHover(false) }
    override func viewDidChangeEffectiveAppearance() { super.viewDidChangeEffectiveAppearance(); needsDisplay = true }
    override func becomeFirstResponder() -> Bool { let r = super.becomeFirstResponder(); needsDisplay = true; return r }
    override func resignFirstResponder() -> Bool { let r = super.resignFirstResponder(); needsDisplay = true; return r }

    override func draw(_ dirtyRect: NSRect) {
        let enabled = isEnabled
        let rect = bounds.insetBy(dx: 0.25, dy: 0.25)
        let path = NSBezierPath(roundedRect: rect, xRadius: corner, yRadius: corner)
        let bg: NSColor?
        let fg: NSColor
        var borderColor: NSColor?
        switch style {
        case .primary:
            bg = (hover || isHighlighted) ? T.brandPrimaryHover : T.brandPrimary
            fg = T.labelOnPrimary
        case .info:
            bg = (hover || isHighlighted) ? T.infoHover : T.infoFill
            fg = T.rgb(0x16150F)
        case .icon:
            bg = (hover || isHighlighted || selected) ? T.hoverBg : nil
            fg = textColor
        case .tab, .iconTab:
            bg = selected ? T.navItemActive : (hover || isHighlighted ? T.hoverBg : nil)
            fg = selected ? T.labelPrimary : (tint ?? T.labelSecondary)
        case .circle:
            bg = (hover || isHighlighted) ? T.hoverBgSolid : T.selector
            fg = T.labelPrimary
        case .row, .nav:
            bg = selected ? T.navItemActive : (hover || isHighlighted ? T.hoverBg : nil)
            fg = textColor
        case .cta:
            // Primary CTA is the blue capsule with light ink.
            bg = (hover || isHighlighted) ? T.ctaHover : T.ctaFill
            fg = T.labelOnPrimary
        case .filled:
            bg = (hover || isHighlighted) ? T.hoverBgSolid : T.selector
            fg = T.labelPrimary
            borderColor = T.borderL2
        case .danger:
            bg = hover ? T.hoverBgDanger : nil
            fg = hover ? T.errorPrimary : T.labelSecondary
            borderColor = hover ? nil : T.borderL2
        case .plain:
            bg = (hover || isHighlighted) ? T.hoverBg : nil
            fg = textColor
        }
        if let bg { (enabled ? bg : bg.withAlphaComponent(bg.alphaComponent * 0.4)).setFill(); path.fill() }
        if let borderColor {
            (enabled ? borderColor : borderColor.withAlphaComponent(borderColor.alphaComponent * 0.4)).setStroke()
            path.lineWidth = 0.5; path.stroke()
        }
        drawContent(path: path, fg: fg.withAlphaComponent(enabled ? 1 : 0.38))
        if !badge.isEmpty { drawBadge() }
        if window?.firstResponder == self {
            T.accent.withAlphaComponent(0.7).setStroke()
            let ring = NSBezierPath(roundedRect: bounds.insetBy(dx: 1.5, dy: 1.5), xRadius: corner + 2, yRadius: corner + 2)
            ring.lineWidth = 2
            ring.stroke()
        }
    }

    /// State badge: accent capsule with light ink, top-trailing corner.
    private func drawBadge() {
        let attrs: [NSAttributedString.Key: Any] = [.font: T.ui(9.5, .semibold), .foregroundColor: T.labelOnPrimary]
        let text = badge as NSString
        let ts = text.size(withAttributes: attrs)
        let h: CGFloat = 13, w = max(h, ts.width + 7)
        let r = NSRect(x: bounds.maxX - w - 1, y: isFlipped ? 1 : bounds.maxY - h - 1, width: w, height: h)
        T.ctaFill.setFill()
        NSBezierPath(roundedRect: r, xRadius: h / 2, yRadius: h / 2).fill()
        text.draw(at: NSPoint(x: r.midX - ts.width / 2, y: r.midY - ts.height / 2), withAttributes: attrs)
    }

    /// Largest rect with `size`'s aspect ratio that fits in `box`, centered
    /// and pixel-aligned. Degenerate sizes fall back to the box itself.
    static func aspectFit(_ size: NSSize, in box: NSRect) -> NSRect {
        guard size.width > 0, size.height > 0 else { return box }
        let scale = min(box.width / size.width, box.height / size.height)
        let w = size.width * scale, h = size.height * scale
        // Round the origin only: .integral grows the size and would
        // reintroduce a sub-pixel stretch.
        return NSRect(x: (box.midX - w / 2).rounded(), y: (box.midY - h / 2).rounded(), width: w, height: h)
    }

    private func drawContent(path: NSBezierPath, fg: NSColor) {
        let f = font ?? defaultFont
        var x: CGFloat = style == .row || style == .nav ? 10 : (title.isEmpty && style == .icon ? 0 : 10)
        if style == .icon && symbol != nil { x = (bounds.width - 16) / 2 }
        if let symbol, let image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: iconPointSize, weight: .medium)) {
            let iconSize: CGFloat = iconBox ?? ((style == .nav || style == .icon || style == .circle) ? 16 : 15)
            let iconRect = NSRect(x: title.isEmpty ? (bounds.width - iconSize) / 2 : x,
                                  y: (bounds.height - iconSize) / 2, width: iconSize, height: iconSize)
            // SF Symbols are rarely square (eye is wide, doc.on.doc is tall).
            // Drawing one into the square box stretched it; aspect-fit and
            // center it instead so every glyph keeps its drawn proportions.
            let fitted = Self.aspectFit(image.size, in: iconRect)
            let tinted = NSImage(size: fitted.size, flipped: false) { r in
                image.draw(in: r)
                (self.iconTint.map { self.isEnabled ? $0 : $0.withAlphaComponent(0.38) } ?? fg).setFill()
                r.fill(using: .sourceIn)
                return true
            }
            tinted.draw(in: fitted)
            if !title.isEmpty { x += iconSize + (style == .nav ? 8 : 7) }
        }
        if !title.isEmpty {
            let p = NSMutableParagraphStyle(); p.lineBreakMode = .byTruncatingTail
            let attrs: [NSAttributedString.Key: Any] = [.font: f, .foregroundColor: fg, .paragraphStyle: p]
            let h = (title as NSString).size(withAttributes: attrs).height
            let capW: CGFloat = (caption.isEmpty ? 8 : (caption as NSString).size(withAttributes: [.font: T.ui(12)]).width + 12)
                + trailingInset
            (title as NSString).draw(in: NSRect(x: x, y: (bounds.height - h) / 2,
                                                 width: max(0, bounds.width - x - capW), height: h),
                                     withAttributes: attrs)
        }
        if !caption.isEmpty {
            let capColor: NSColor
            switch style {
            case .cta, .info, .primary: capColor = fg.withAlphaComponent(0.75)
            default: capColor = T.labelTertiary
            }
            let attrs: [NSAttributedString.Key: Any] = [.font: T.ui(12), .foregroundColor: capColor]
            let size = (caption as NSString).size(withAttributes: attrs)
            (caption as NSString).draw(at: NSPoint(x: bounds.width - size.width - 10,
                                                   y: (bounds.height - size.height) / 2),
                                       withAttributes: attrs)
        }
    }
    private var iconPointSize: CGFloat {
        if let iconBox { return iconBox - 2 } // same 2pt margin the style sizes use
        switch style { case .nav, .row, .icon, .circle: return 14; case .tab: return 13; default: return 13 }
    }
}

extension NSView {
    func pin(to parent: NSView, inset: CGFloat = 0) {
        translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            leadingAnchor.constraint(equalTo: parent.leadingAnchor, constant: inset),
            trailingAnchor.constraint(equalTo: parent.trailingAnchor, constant: -inset),
            topAnchor.constraint(equalTo: parent.topAnchor, constant: inset),
            bottomAnchor.constraint(equalTo: parent.bottomAnchor, constant: -inset),
        ])
    }
}

func vertical(_ views: [NSView], spacing: CGFloat = 8) -> NSStackView {
    let s = NSStackView(views: views)
    s.orientation = .vertical; s.alignment = .leading; s.spacing = spacing
    return s
}

func horizontal(_ views: [NSView], spacing: CGFloat = 8) -> NSStackView {
    let s = NSStackView(views: views)
    s.orientation = .horizontal; s.alignment = .centerY; s.spacing = spacing
    return s
}

extension NSStackView {
    /// Pin one arranged subview to the stack's content width.
    /// Vertical stacks use this instead of `alignment = .width`, which does
    /// not stretch on macOS — children keep intrinsic width, trailing.
    func pinRowWidth(_ v: NSView) {
        v.widthAnchor.constraint(equalTo: widthAnchor, constant: -(edgeInsets.left + edgeInsets.right)).isActive = true
    }
    /// Stretch every current arranged subview to the full content width.
    func stretchRows() {
        alignment = .leading
        arrangedSubviews.forEach(pinRowWidth)
    }
}

/// A label that wraps and reports a correct intrinsic height inside stack views.
final class WrappingLabel: NSTextField {
    override init(frame: NSRect) {
        super.init(frame: frame)
        isEditable = false; isBordered = false; drawsBackground = false
        isSelectable = true; maximumNumberOfLines = 0
        cell?.wraps = true; cell?.isScrollable = false
        setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    }
    required init?(coder: NSCoder) { fatalError() }
    override func setFrameSize(_ newSize: NSSize) {
        let changed = abs(newSize.width - frame.width) > 0.5
        super.setFrameSize(newSize)
        if changed { preferredMaxLayoutWidth = max(1, newSize.width); invalidateIntrinsicContentSize() }
    }
    override var intrinsicContentSize: NSSize {
        let width = preferredMaxLayoutWidth > 1 ? preferredMaxLayoutWidth : max(1, bounds.width)
        let size = cell?.cellSize(forBounds: NSRect(x: 0, y: 0, width: width, height: 1_000_000)) ?? .zero
        return NSSize(width: NSView.noIntrinsicMetric, height: ceil(size.height))
    }
}

/// The official "Preview"-style badge: mono 12px pill on the business-tertiary wash.
final class Badge: Surface {
    private let label: NSTextField
    init(_ text: String) {
        label = T.label(text, T.mono(12, .medium), T.accentBluish)
        super.init(T.accentSoft, radius: 8, stroke: T.borderL2)
        label.alignment = .center
        let content = horizontal([label], spacing: 0)
        content.edgeInsets = NSEdgeInsets(top: 1, left: 7, bottom: 1, right: 7)
        addSubview(content); content.pin(to: self)
    }
    required init?(coder: NSCoder) { fatalError() }
}

/// Centered calm empty state: symbol over a title and one quiet subtitle.
/// Used by every inspector pane so blank states guide instead of staring.
final class EmptyState: View {
    init(symbol: String, title: String, subtitle: String) {
        super.init(frame: .zero)
        let img = T.icon(symbol, size: 26, color: T.labelTertiary)
        img.widthAnchor.constraint(equalToConstant: 30).isActive = true
        img.heightAnchor.constraint(equalToConstant: 30).isActive = true
        let t = T.label(title, T.ui(13, .semibold), T.labelSecondary)
        t.alignment = .center
        let s = T.label(subtitle, T.ui(12), T.labelTertiary)
        s.alignment = .center
        let col = vertical([img, t, s], spacing: 6)
        col.alignment = .centerX
        addSubview(col)
        col.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            col.centerXAnchor.constraint(equalTo: centerXAnchor),
            col.centerYAnchor.constraint(equalTo: centerYAnchor),
            col.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor, constant: 16),
            col.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -16),
        ])
    }
    required init?(coder: NSCoder) { fatalError() }
}

/// Small pill used for status text and meta labels.
final class Pill: Surface {
    private let label: NSTextField
    private let dot = TintedView(T.labelSecondary, radius: 3)
    var title: String {
        get { label.stringValue }
        set { label.stringValue = newValue; invalidateIntrinsicContentSize() }
    }
    init(_ text: String = "", color: NSColor = T.labelSecondary, dot: Bool = false) {
        label = T.label(text, T.ui(12, .medium), color)
        super.init(T.selector, radius: 8, stroke: T.borderL2)
        label.alignment = .center
        let content = horizontal(dot ? [self.dot, label] : [label], spacing: 5)
        content.edgeInsets = NSEdgeInsets(top: 3, left: 9, bottom: 3, right: 9)
        addSubview(content); content.pin(to: self)
        if dot {
            self.dot.tint = color
            self.dot.widthAnchor.constraint(equalToConstant: 6).isActive = true
            self.dot.heightAnchor.constraint(equalToConstant: 6).isActive = true
        }
    }
    required init?(coder: NSCoder) { fatalError() }
}

/// Official select chip: 28px, radius 8, transparent, chevron at right, hover wash.
/// Pops an NSMenu on click — used for the model picker.
final class SelectChip: NSView {
    var items: [String] = [] { didSet { rebuild() } }
    var selected: String? { didSet { rebuild() } }
    /// When set, the chip shows this grayed status text instead of a selection.
    var statusText: String? { didSet { rebuild() } }
    var onSelect: (String) -> Void = { _ in }
    var enabled = true { didSet { needsDisplay = true; rebuild() } }
    private let titleLabel = T.label("", T.ui(13, .medium), T.labelSecondary)
    private let chevron = T.icon("chevron.down", size: 11, color: T.labelCaption)
    private var hover = false
    private var tracking: NSTrackingArea?

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.cornerRadius = 8
        heightAnchor.constraint(equalToConstant: 28).isActive = true
        let content = horizontal([titleLabel, chevron], spacing: 4)
        content.edgeInsets = NSEdgeInsets(top: 0, left: 8, bottom: 0, right: 8)
        addSubview(content); content.pin(to: self)
        let click = NSClickGestureRecognizer(target: self, action: #selector(openMenu))
        addGestureRecognizer(click)
        setAccessibilityLabel("Select")
        setAccessibilityRole(.popUpButton)
        // A plain NSView is ignored by accessibility unless it opts in: the
        // role and press handler above were unreachable to VoiceOver.
        setAccessibilityElement(true)
    }
    required init?(coder: NSCoder) { fatalError() }
    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override func accessibilityPerformPress() -> Bool { openMenu(); return true }
    override func keyDown(with event: NSEvent) {
        if event.keyCode == 36 || event.keyCode == 49 { openMenu(); return }
        super.keyDown(with: event)
    }

    private func rebuild() {
        // keep selection if still present
        if let s = selected, !items.contains(s), selected != items.first { selected = items.first }
        if let st = statusText {
            titleLabel.stringValue = st
            titleLabel.textColor = T.labelCaption
        } else {
            titleLabel.stringValue = selected ?? items.first ?? ""
            titleLabel.textColor = enabled ? T.labelSecondary : T.labelCaption
        }
        setAccessibilityValue(titleLabel.stringValue)
        setAccessibilityEnabled(enabled)
        chevron.contentTintColor = T.labelCaption
        needsDisplay = true
    }

    @objc private func openMenu() {
        guard enabled, !items.isEmpty else { return }
        window?.makeFirstResponder(self)
        let menu = NSMenu()
        for item in items {
            let mi = NSMenuItem(title: item, action: #selector(pick(_:)), keyEquivalent: "")
            mi.target = self; mi.representedObject = item
            if item == (selected ?? items.first) { mi.state = .on }
            menu.addItem(mi)
        }
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: bounds.height), in: self)
    }
    @objc private func pick(_ item: NSMenuItem) {
        guard let v = item.representedObject as? String else { return }
        selected = v; onSelect(v)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let t = tracking { removeTrackingArea(t) }
        let t = NSTrackingArea(rect: .zero, options: [.inVisibleRect, .activeAlways, .mouseEnteredAndExited], owner: self, userInfo: nil)
        addTrackingArea(t); tracking = t
    }
    override func mouseEntered(with event: NSEvent) { hover = true; needsDisplay = true }
    override func mouseExited(with event: NSEvent) { hover = false; needsDisplay = true }
    override func viewDidChangeEffectiveAppearance() { super.viewDidChangeEffectiveAppearance(); needsDisplay = true }
    override func draw(_ dirtyRect: NSRect) {
        if hover && enabled { T.hoverBg.setFill(); NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: 8, yRadius: 8).fill() }
        if window?.firstResponder === self {
            T.accent.withAlphaComponent(0.7).setStroke()
            let ring = NSBezierPath(roundedRect: bounds.insetBy(dx: 1.5, dy: 1.5), xRadius: 9, yRadius: 9)
            ring.lineWidth = 2
            ring.stroke()
        }
    }
}

final class FocusableActionView: View {
    var onPress: () -> Void = {}

    override init(frame: NSRect) {
        super.init(frame: frame)
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        addGestureRecognizer(NSClickGestureRecognizer(target: self, action: #selector(pressed)))
    }
    required init?(coder: NSCoder) { fatalError() }
    override var acceptsFirstResponder: Bool { true }
    override func keyDown(with event: NSEvent) {
        if event.keyCode == 36 || event.keyCode == 49 { onPress(); return }
        super.keyDown(with: event)
    }
    override func accessibilityPerformPress() -> Bool { onPress(); return true }
    @objc private func pressed() {
        window?.makeFirstResponder(self)
        onPress()
    }
    override func draw(_ dirtyRect: NSRect) {
        guard window?.firstResponder === self else { return }
        T.accent.withAlphaComponent(0.7).setStroke()
        let ring = NSBezierPath(roundedRect: bounds.insetBy(dx: 1.5, dy: 1.5), xRadius: 9, yRadius: 9)
        ring.lineWidth = 2
        ring.stroke()
    }
}

enum PluginAutomationRows {
    static func plugins(intro: String, onToggle: @escaping (PluginRecord) -> Void, onDelete: ((PluginRecord) -> Void)? = nil) -> [NSView] {
        var rows: [NSView] = [T.label(intro, T.ui(12), T.labelSecondary),
                              T.label("Enabled plugins run arbitrary code, including shell commands when Tool permissions allow shell. Only enable plugins you trust.", T.ui(12), T.errorPrimary)]
        let records = PluginEngine.shared.records
        for record in records {
            let button = ActionButton(record.name, symbol: "puzzlepiece.extension", style: .row) {
                onToggle(record)
            }
            button.caption = record.broken.map { _ in
                "Error · \(record.enabled ? "Enabled" : "Disabled")"
            } ?? (record.enabled ? "Enabled" : "Disabled")
            button.toolTip = record.broken ?? record.id
            if let onDelete {
                let record = record
                rows.append(deletableRow(button: button, label: "Uninstall plugin \(record.name)") { onDelete(record) })
            } else {
                rows.append(button)
            }
        }
        if records.isEmpty {
            rows.append(T.label("No plugins installed.", T.ui(12), T.labelSecondary))
        }
        return rows
    }

    static func automations(intro: String, onToggle: @escaping (AutomationTask) -> Void, onDelete: ((AutomationTask) -> Void)? = nil) -> [NSView] {
        var rows: [NSView] = [T.label(intro, T.ui(12), T.labelSecondary)]
        let tasks = Scheduler.shared.tasks
        for task in tasks {
            let button = ActionButton(task.title, symbol: "clock", style: .row) {
                onToggle(task)
            }
            button.caption = task.enabled ? "On" : "Off"
            button.toolTip = task.schedule.summary
            if let onDelete {
                let task = task
                rows.append(deletableRow(button: button, label: "Delete automation \(task.title)") { onDelete(task) })
            } else {
                rows.append(button)
            }
        }
        if tasks.isEmpty {
            rows.append(T.label("No scheduled tasks.", T.ui(12), T.labelSecondary))
        }
        return rows
    }

    /// Row button plus a trailing trash control. The button keeps its full
    /// caption (the trash sits beside it, never over it) and expands to the
    /// row width; the trash keeps a fixed 24px target.
    private static func deletableRow(button: ActionButton, label: String, onDelete: @escaping () -> Void) -> NSView {
        let del = ActionButton(symbol: "trash", style: .icon, action: onDelete)
        del.setFixedSize(24)
        del.toolTip = label
        del.setAccessibilityLabel(label)
        del.tint = T.labelSecondary
        button.setContentHuggingPriority(.defaultLow, for: .horizontal)
        return horizontal([button, del], spacing: 8)
    }
}
