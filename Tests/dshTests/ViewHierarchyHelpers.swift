import AppKit

func collectButtons(in view: NSView) -> [NSButton] {
    var out: [NSButton] = []
    if let b = view as? NSButton { out.append(b) }
    for sub in view.subviews { out += collectButtons(in: sub) }
    return out
}
