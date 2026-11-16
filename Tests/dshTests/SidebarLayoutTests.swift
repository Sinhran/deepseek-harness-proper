import XCTest
import AppKit
@testable import DSHCore

/// No window-edge strip, no in-window pane toggles: the sidebar is the only
/// left pane and both toggles live in the View menu (keyboard reachable).
/// Nothing may live in the window titlebar, and both side panes must stay
/// user-resizable.
final class SidebarLayoutTests: XCTestCase {
    private func makeController() -> MainWindowController {
        let wc = MainWindowController()
        wc.window?.contentView?.layoutSubtreeIfNeeded()
        wc.window?.contentView?.layoutSubtreeIfNeeded()
        return wc
    }

    private func windowButtons(_ wc: MainWindowController) -> [NSButton] {
        guard let content = wc.window?.contentView else { return [] }
        return collectButtons(in: content)
    }

    private func isDescendant(_ view: NSView, of ancestor: NSView) -> Bool {
        var current: NSView? = view
        while let c = current {
            if c === ancestor { return true }
            current = c.superview
        }
        return false
    }

    private func frameInWindow(_ view: NSView) -> NSRect {
        view.convert(view.bounds, to: nil)
    }

    private func toggle(named name: String, in wc: MainWindowController) -> NSButton? {
        windowButtons(wc).first { $0.toolTip == name }
    }

    func testPaneTogglesAreNotInTitlebar() {
        let wc = makeController()
        XCTAssertTrue(wc.window?.titlebarAccessoryViewControllers.isEmpty ?? false,
                      "pane toggles must not live in the window titlebar")
    }

    func testNoWindowEdgeStrip() {
        // No 56px rail, no in-window pane toggles: the sidebar is the only
        // left pane, and both toggles live in the View menu. Collapsing
        // removes the pane wholesale; reopen it from the menu.
        let wc = makeController()
        let panes = wc.splitView.arrangedSubviews
        XCTAssertEqual(panes.count, 2, "split holds exactly [sidebar, center]")
        XCTAssertTrue(panes.first === wc.sidebar.view)
        let tips = windowButtons(wc).compactMap { $0.toolTip }
        XCTAssertFalse(tips.contains("Toggle sidebar"), "no sidebar toggle may live in-window")
        XCTAssertFalse(tips.contains("Toggle inspector"), "no inspector toggle may live in-window")
        wc.collapseSidebar()
        wc.splitView.layoutSubtreeIfNeeded()
        XCTAssertFalse(wc.splitView.arrangedSubviews.contains(wc.sidebar.view),
                       "collapse removes the whole sidebar pane")
        let collapsedTips = windowButtons(wc).compactMap { $0.toolTip }
        XCTAssertFalse(collapsedTips.contains("Toggle sidebar"), "collapsing must not summon a replacement toggle")
        XCTAssertFalse(collapsedTips.contains("Toggle inspector"), "collapsing must not summon a replacement toggle")
        wc.expandSidebar()
        wc.splitView.layoutSubtreeIfNeeded()
        XCTAssertTrue(wc.splitView.arrangedSubviews.contains(wc.sidebar.view),
                      "expand restores the whole sidebar pane")
    }

    func testNoPaneLocalToggles() {
        let wc = makeController()
        wc.toggleInspector()
        wc.splitView.layoutSubtreeIfNeeded()
        let retired = ["Hide sidebar", "Hide inspector", "Show inspector",
                       "Show inspector (⌘I)", "Inspector (⌘I)", "Sessions", "Expand sidebar"]
        let found = windowButtons(wc).compactMap { $0.toolTip }.filter { retired.contains($0) }
        XCTAssertTrue(found.isEmpty, "no pane-local or chat toggle may remain: \(found)")
        wc.toggleInspector()
    }

    func testSidebarToggleShowsAndHidesPane() {
        let wc = makeController()
        func hasSidebar() -> Bool {
            wc.splitView.arrangedSubviews.contains(wc.sidebar.view)
        }
        XCTAssertTrue(hasSidebar())
        wc.collapseSidebar()
        XCTAssertFalse(hasSidebar(), "collapse removes the sidebar pane")
        wc.expandSidebar()
        XCTAssertTrue(hasSidebar(), "expand restores the sidebar pane")
    }

    /// Sidebar popovers (Plugins, Automations) must use a fixed document
    /// width with no coupling to the live clip width. Coupling content or
    /// document width to the clip lets the layout engine satisfy the system
    /// by resizing the panel window itself (observed both ways: 460pt
    /// collapsing to a ~64pt sliver, and stretching unboundedly to fit the
    /// longest label).
    func testPanelScrollLocksDocumentWidth() {
        let sidebar = SidebarViewController()
        sidebar.loadView()
        sidebar.showPlugins()
        guard let panel = NSApp.windows.first(where: { $0.title == "Plugins" }),
              let scroll = panel.contentView as? NSScrollView,
              let doc = scroll.documentView,
              let content = doc.subviews.first else {
            return XCTFail("Plugins panel must host a scroll view with document content")
        }
        panel.layoutIfNeeded()
        XCTAssertEqual(panel.frame.width, 460, accuracy: 1.0,
                       "the panel must keep its designed width")
        let clip = scroll.contentView
        func allConstraints(in view: NSView) -> [NSLayoutConstraint] {
            view.constraints + view.subviews.flatMap(allConstraints(in:))
        }
        let constraints = allConstraints(in: scroll)
        func widthRelation(between a: NSView, and b: NSView) -> Bool {
            constraints.contains {
                ($0.firstAttribute == .width || $0.secondAttribute == .width) &&
                (($0.firstItem as? NSView) === a && ($0.secondItem as? NSView) === b ||
                 ($0.firstItem as? NSView) === b && ($0.secondItem as? NSView) === a)
            }
        }
        XCTAssertTrue(constraints.contains {
            $0.relation == .equal && $0.firstAttribute == .width &&
            ($0.firstItem as? NSView) === doc && $0.secondItem == nil &&
            $0.constant == 460
        }, "the document width must be a fixed design constant")
        XCTAssertFalse(widthRelation(between: doc, and: clip),
                       "the document must not couple its width to the clip")
        XCTAssertFalse(widthRelation(between: content, and: clip),
                       "content must not couple its width to the clip")
    }

    /// The fish mark lives exactly once on the left edge, in the sidebar's
    /// icon rail beside the DeepSeek wordmark, with no second copy anywhere.
    func testBrandMarkAppearsOnce() {
        let sidebar = SidebarViewController()
        sidebar.loadView()
        func fishMarks(in view: NSView) -> [BrandMarkView] {
            var out: [BrandMarkView] = []
            if let b = view as? BrandMarkView, b.kind == .fish { out.append(b) }
            for sub in view.subviews { out += fishMarks(in: sub) }
            return out
        }
        func texts(in view: NSView) -> [String] {
            var out: [String] = []
            if let t = view as? NSTextField { out.append(t.stringValue) }
            for sub in view.subviews { out += texts(in: sub) }
            return out
        }
        XCTAssertEqual(fishMarks(in: sidebar.view).count, 1, "the sidebar owns the single fish mark")
        XCTAssertTrue(texts(in: sidebar.view).contains("DeepSeek"), "the sidebar keeps the wordmark")
    }

    func testDividerRangesEnforced() {
        // The delegate clamps every divider to its panes' widths, and
        // setPosition honors the same range end to end — on a plain split
        // view this works headless, with no controller second-guessing it.
        // Panes are [sidebar, center]: divider 0 trails the sidebar.
        let wc = makeController()
        let split = wc.splitView
        split.frame = NSRect(x: 0, y: 0, width: 1240, height: 788)
        XCTAssertEqual(split.arrangedSubviews.count, 2)
        // The divider clamps to the 220...360 sidebar range.
        XCTAssertEqual(wc.splitView(split, constrainMinCoordinate: 0, ofSubviewAt: 0),
                       220, accuracy: 0.5)
        XCTAssertEqual(wc.splitView(split, constrainMaxCoordinate: 9999, ofSubviewAt: 0),
                       360, accuracy: 0.5)
        split.setPosition(200, ofDividerAt: 0)
        XCTAssertEqual(wc.sidebar.view.frame.width, 220, accuracy: 2.0,
                       "drag below range clamps to the 220 minimum")
        split.setPosition(1000, ofDividerAt: 0)
        XCTAssertEqual(wc.sidebar.view.frame.width, 360, accuracy: 2.0,
                       "drag above range clamps to the 360 maximum")
        split.setPosition(300, ofDividerAt: 0)
        XCTAssertEqual(wc.sidebar.view.frame.width, 300, accuracy: 2.0,
                       "a drag inside the range sticks exactly")
        // Only the inspector may collapse (double-click its divider).
        XCTAssertFalse(wc.splitView(split, canCollapseSubview: wc.sidebar.view))
        XCTAssertFalse(wc.splitView(split, canCollapseSubview: wc.chat.view))
        XCTAssertTrue(wc.splitView(split, canCollapseSubview: wc.inspector.view))
    }
}
