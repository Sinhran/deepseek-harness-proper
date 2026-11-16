import AppKit

/// dsh-proper design system — tokens resolved from the official DeepSeek Harness desktop UI.
/// Every color is a dynamic NSColor so light/dark switches live without a reload.
enum T {

    static func dyn(_ light: NSColor, _ dark: NSColor) -> NSColor {
        NSColor(name: nil) { a in
            let m = a.bestMatch(from: [.darkAqua, .vibrantDark, .aqua, .vibrantLight])
            return (m == .aqua || m == .vibrantLight) ? light : dark
        }
    }

    /// sRGB hex color, e.g. `c(0xFFFFFF, 0x151517)`.
    static func rgb(_ hex: UInt32, alpha: CGFloat = 1) -> NSColor {
        NSColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
                green: CGFloat((hex >> 8) & 0xFF) / 255,
                blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
    }

    /// Official token: light value first, dark value second.
    static func tok(_ light: UInt32, _ dark: UInt32, alpha: CGFloat = 1) -> NSColor {
        dyn(rgb(light, alpha: alpha), rgb(dark, alpha: alpha))
    }

    /// Official token where the dark side is a translucent white/black wash.
    static func wash(_ lightAlpha: CGFloat, _ darkAlpha: CGFloat, darkIsWhite: Bool = true) -> NSColor {
        dyn(NSColor.black.withAlphaComponent(lightAlpha),
            (darkIsWhite ? NSColor.white : NSColor.black).withAlphaComponent(darkAlpha))
    }

    // MARK: - Surfaces — Tern register: warm near-black, warm paper light.

    static let bgBase        = tok(0xF5F4F0, 0x050505)   // warm paper / near-black
    static let bgLayer2      = tok(0xFFFFFF, 0x161511)   // cards, composer

    static let sidebarFill   = tok(0xEFEEE9, 0x0B0A07)
    static let navItemActive = tok(0xE4E2DA, 0x24221B)

    static let bubble        = tok(0xFFFFFF, 0x1C1B15)   // user message
    static let inputMajor    = tok(0xFFFFFF, 0x161511)   // composer card
    static let selector      = tok(0xF8F7F4, 0x1E1D18)

    static let codeBlock       = tok(0xF1EFEA, 0x0B0A07)
    static let codeBlockBanner = tok(0xEAE8E2, 0x1E1D18)

    // MARK: - Labels — Tern ink ramp.

    static let labelPrimary    = tok(0x16150F, 0xF7F6F2)
    static let labelSecondary  = tok(0x5B5952, 0xB9B7B0)
    // Tertiary and caption carry real text (section labels, timestamps,
    // placeholders, chevrons), so both sides meet WCAG AA 4.5:1 on every
    // surface they sit on — bgBase, sidebarFill, and bgLayer2. The previous
    // light values measured 2.98 and 2.14 on bgBase.
    static let labelTertiary   = tok(0x6B6960, 0x908E87)
    static let labelCaption    = tok(0x6E6C63, 0x85837A)
    static let labelPrimaryDim = tok(0x16150F, 0xE9E7E0)
    static let labelOnPrimary  = tok(0xFFFFFF, 0x050505)
    static let labelInverted   = tok(0xFFFFFF, 0x353430)
    static let labelBluish     = tok(0x1D4ED8, 0x93C5FD)

    // MARK: - Borders — Tern hairlines (#ffffff14 / #ffffff26 dark).

    static let borderL1 = dyn(NSColor.black.withAlphaComponent(0.04), NSColor.white.withAlphaComponent(0.05))
    static let borderL1c = borderL1
    static let borderL2 = dyn(NSColor.black.withAlphaComponent(0.08), NSColor.white.withAlphaComponent(0.08))
    static let borderL3 = dyn(NSColor.black.withAlphaComponent(0.12), NSColor.white.withAlphaComponent(0.12))

    // MARK: - Brand — DeepSeek blue (#4D6BFE family), monochrome primaries.

    static let brandPrimary       = tok(0x16150F, 0xF7F6F2)
    static let brandPrimaryHover  = tok(0x4A4945, 0xE9E7E0)
    /// True blue, one hue for the whole ramp: rich enough to read as
    /// blue on warm paper, light enough for dark ink on fills.
    static let brandBlue          = tok(0x2563EB, 0x60A5FA)
    static let accent             = tok(0x2563EB, 0x60A5FA)
    static let accentSoft         = tok(0xDBEAFE, 0x15344E)
    static let accentText         = tok(0x1D4ED8, 0x93C5FD)
    static let accentBluish       = labelBluish

    /// Send/stop circle and primary fills — true blue; deeper on hover
    /// in light, lighter on hover in dark.
    static let infoFill  = tok(0x60A5FA, 0x3B82F6)
    static let infoHover = tok(0x3B82F6, 0x60A5FA)
    /// Primary CTA fill — DeepSeek blue, never amber.
    static let ctaFill  = tok(0x2563EB, 0x60A5FA)
    static let ctaHover = tok(0x1D4ED8, 0x93C5FD)

    static let hoverBg       = dyn(NSColor.black.withAlphaComponent(0.04), NSColor.white.withAlphaComponent(0.05))
    static let hoverBgSolid  = tok(0xEAE8E2, 0x24221B)
    static let hoverBgDanger = dyn(NSColor(srgbRed: 0xBA/255, green: 0x27/255, blue: 0x23/255, alpha: 0.08),
                                    NSColor(srgbRed: 0xF0/255, green: 0x77/255, blue: 0x6D/255, alpha: 0.15))

    // MARK: - Status — Tern's ok/err/warn palette.

    // Light-mode warn/success are darkened to clear AA 4.5:1 on their own
    // washes (warnTertiary) and on code surfaces; dark-mode values already do.
    static let warnLabel   = tok(0x9C4F00, 0xFFCB6B)
    static let warnTertiary  = tok(0xFDF3DA, 0x2A2210)
    static let errorPrimary  = tok(0xBA2723, 0xF0776D)
    static let successText    = tok(0x237A34, 0x6FD08C)

    // MARK: - Diffs

    static let diffAddBg  = dyn(NSColor(srgbRed: 0x22/255, green: 0x9E/255, blue: 0x44/255, alpha: 0.12),
                                NSColor(srgbRed: 0x6F/255, green: 0xD0/255, blue: 0x8C/255, alpha: 0.12))
    static let diffDelBg  = dyn(NSColor(srgbRed: 0xBA/255, green: 0x27/255, blue: 0x23/255, alpha: 0.10),
                                NSColor(srgbRed: 0xF0/255, green: 0x77/255, blue: 0x6D/255, alpha: 0.12))
    static let diffAddText = tok(0x237A34, 0x6FD08C)
    static let diffDelText = tok(0xBA2723, 0xF0776D)

    // MARK: - Legacy aliases (kept so untouched call sites keep working)

    static let text      = labelPrimary
    static let secondary = labelSecondary
    static let contentBg = bgBase
    static let codeBg    = codeBlock

    // MARK: - Fonts

    /// UI text — the macOS system stack (San Francisco).
    static func ui(_ size: CGFloat = 14, _ w: NSFont.Weight = .regular) -> NSFont {
        .systemFont(ofSize: size, weight: w)
    }
    /// Display serif for the hero headline — Tern's Fraunces register.
    /// New York (system serif) where available, Georgia as the fallback.
    static func serif(_ size: CGFloat = 26, _ w: NSFont.Weight = .regular) -> NSFont {
        if let desc = NSFont.systemFont(ofSize: size).fontDescriptor.withDesign(.serif) {
            let weighted = desc.addingAttributes([NSFontDescriptor.AttributeName.traits: [NSFontDescriptor.TraitKey.weight: w]])
            if let f = NSFont(descriptor: weighted, size: size) { return f }
        }
        return NSFont(name: "Georgia", size: size) ?? .systemFont(ofSize: size, weight: w)
    }
    /// Code — SF Mono first, matching the official code stack.
    static func mono(_ size: CGFloat = 11, _ w: NSFont.Weight = .regular) -> NSFont {
        .monospacedSystemFont(ofSize: size, weight: w)
    }

    // MARK: - Components

    static func label(_ s: String, _ font: NSFont? = nil, _ color: NSColor? = nil) -> NSTextField {
        let l = NSTextField(labelWithString: s)
        l.font = font ?? ui()
        l.textColor = color ?? labelPrimary
        l.lineBreakMode = .byTruncatingTail
        return l
    }

    static func icon(_ name: String, size: CGFloat = 14, color: NSColor? = nil) -> NSImageView {
        let img = NSImage(systemSymbolName: name, accessibilityDescription: nil) ?? NSImage()
        let iv = NSImageView(image: img)
        iv.symbolConfiguration = .init(pointSize: size, weight: .medium)
        iv.contentTintColor = color ?? labelSecondary
        return iv
    }

    /// 0.5pt hairline divider.
    static func hairlineView(color: NSColor? = nil) -> NSView {
        HairlineView(color ?? borderL2)
    }

    static func toolIcon(_ name: String) -> String {
        switch name {
        case "read": return "doc.text"
        case "write": return "square.and.pencil"
        case "edit": return "pencil.line"
        case "bash": return "terminal"
        case "grep": return "magnifyingglass"
        case "glob": return "folder"
        case "web_fetch", "web_search": return "globe"
        case "schedule_create", "schedule_list", "schedule_delete": return "clock"
        case "subagent": return "person.2"
        case "plugin_manager": return "puzzlepiece.extension"
        default: return "wrench.and.screwdriver"
        }
    }
}
