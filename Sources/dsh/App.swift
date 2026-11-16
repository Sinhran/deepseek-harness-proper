import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var mainWindow: MainWindowController?

    func applicationDidFinishLaunching(_ n: Notification) {
        buildMenu()
        if Preview.enabled { Preview.seed() }
        switch Settings.shared.appearance {
        case "Dark": NSApp.appearance = NSAppearance(named: .darkAqua)
        case "Light": NSApp.appearance = NSAppearance(named: .aqua)
        default: break
        }
        if CommandLine.arguments.contains("--dark") { NSApp.appearance = NSAppearance(named: .darkAqua) }
        if CommandLine.arguments.contains("--light") { NSApp.appearance = NSAppearance(named: .aqua) }
        let wc = MainWindowController()
        mainWindow = wc
        wc.showWindow(nil)
        wc.window?.makeKeyAndOrderFront(nil)
        if let w = wc.window { reportSessionStorageProblems(in: w) }
        if !Preview.enabled { MCPHub.shared.startEnabled() }
        if let i = CommandLine.arguments.firstIndex(of: "--probe-divider-drag"),
           i + 1 < CommandLine.arguments.count, let dx = Double(CommandLine.arguments[i + 1]) {
            runDividerDragProbe(dx: CGFloat(dx), wc: wc)
        } else if CommandLine.arguments.contains("--probe-divider-drag") {
            print("PROBE divider-drag: usage: dsh --probe-divider-drag <pixels>")
            fflush(stdout)
            exit(2)
        }
        if CommandLine.arguments.contains("--probe-focus") {
            runFocusProbe(wc: wc)
        }
    }

    /// Self-test for composer focus (`--probe-focus`): clicks the editor via
    /// direct mouseDown dispatch (the path a physical click takes), reports
    /// the hit view and the resulting first responder, types and deletes one
    /// character, then exits. Exit 0 iff the editor ends up first responder.
    private func runFocusProbe(wc: MainWindowController) {
        NSApp.activate(ignoringOtherApps: true)
        wc.window?.makeKeyAndOrderFront(nil)
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
            guard let win = wc.window else { print("PROBE focus: no window"); fflush(stdout); exit(2) }
            let tv = wc.chat.input.textView
            func describe(_ r: NSResponder?) -> String {
                guard let r else { return "nil" }
                return NSStringFromClass(type(of: r))
            }
            print("PROBE focus: initial firstResponder=\(describe(win.firstResponder)) isTV=\(win.firstResponder === tv)")
            print("PROBE focus: textView window=\(tv.window != nil) acceptsFR=\(tv.acceptsFirstResponder) editable=\(tv.isEditable) frame=\(tv.frame)")
            print("PROBE focus: tvInChat=\(tv.isDescendant(of: wc.chat.view)) tvRectInChat=\(tv.convert(tv.bounds, to: wc.chat.view)) chatBounds=\(wc.chat.view.bounds)")
            var anc: [String] = []
            var cur: NSView? = tv
            while let c = cur, anc.count < 10 {
                anc.append("\(NSStringFromClass(type(of: c)))\(c.frame)")
                cur = c.superview
            }
            print("PROBE focus: tv chain: \(anc.joined(separator: " <- "))")
            fflush(stdout)
            // What view would a physical click at the editor's center hit?
            let centerSelf = NSPoint(x: tv.bounds.midX, y: tv.bounds.midY)
            let centerChat = tv.convert(centerSelf, to: wc.chat.view)
            print("PROBE focus: centerChat=\(centerChat)")
            for (i, v) in wc.chat.view.subviews.enumerated() {
                print("PROBE focus: root[\(i)] \(NSStringFromClass(type(of: v)))\(v.frame) hidden=\(v.isHidden)")
            }
            // Descend manually level by level to find who refuses the hit.
            do {
                var v: NSView = wc.chat.view
                var p = centerChat
                for _ in 0..<10 {
                    let hit = v.hitTest(p)
                    print("PROBE focus: descend \(NSStringFromClass(type(of: v))) point=\(p) -> \(hit.map { NSStringFromClass(type(of: $0)) } ?? "nil")")
                    guard let h = hit, h !== v else { break }
                    p = h.convert(p, from: v)
                    v = h
                }
                fflush(stdout)
            }
            if let hit = wc.chat.view.hitTest(centerChat) {
                var chain: [String] = []
                var cur: NSView? = hit
                while let c = cur, chain.count < 8 {
                    chain.append("\(NSStringFromClass(type(of: c)))\(c.frame)")
                    if c === wc.chat.view { break }
                    cur = c.superview
                }
                print("PROBE focus: hitTest -> \(chain.joined(separator: " <- "))")
            } else {
                print("PROBE focus: hitTest -> nil")
            }
            fflush(stdout)
            // Direct-dispatch a click at the editor center.
            let c = tv.convert(centerSelf, to: nil)
            let wnum = win.windowNumber
            let t = ProcessInfo.processInfo.systemUptime
            var n = 7000
            func ev(_ type: NSEvent.EventType, _ pt: NSPoint, _ ts: TimeInterval) -> NSEvent? {
                n += 1
                return NSEvent.mouseEvent(with: type, location: pt, modifierFlags: [],
                                          timestamp: ts, windowNumber: wnum, context: nil,
                                          eventNumber: n, clickCount: 1,
                                          pressure: type == .leftMouseUp ? 0 : 1)
            }
            guard let down = ev(.leftMouseDown, c, t), let up = ev(.leftMouseUp, c, t + 0.03) else {
                print("PROBE focus: event alloc failed"); fflush(stdout); exit(2)
            }
            NSApp.postEvent(up, atStart: false)
            tv.mouseDown(with: down)
            let focused = win.firstResponder === tv
            print("PROBE focus: after click firstResponder=\(describe(win.firstResponder)) focused=\(focused)")
            if focused {
                tv.insertText("x", replacementRange: NSRange(location: tv.string.count, length: 0))
                print("PROBE focus: typed string=\(tv.string.debugDescription)")
                tv.deleteBackward(nil)
                print("PROBE focus: cleaned string=\(tv.string.debugDescription)")
            }
            fflush(stdout)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { exit(focused ? 0 : 1) }
        }
    }

    /// Self-test for the sidebar divider: drives the REAL AppKit tracking
    /// loop with synthetic mouse events (same path as a physical drag — no
    /// external automation needed), prints before/after widths, restores the
    /// pane, and exits. The probe window takes focus for ~2 seconds.
    private func runDividerDragProbe(dx: CGFloat, wc: MainWindowController) {
        wc.probeNoSave = true
        NSApp.activate(ignoringOtherApps: true)
        wc.window?.makeKeyAndOrderFront(nil)
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
            let split = wc.splitView
            // Start from a known mid-range width so either direction is a
            // meaningful test regardless of the saved width.
            if let i = split.arrangedSubviews.firstIndex(of: wc.sidebar.view) {
                split.setPosition(300, ofDividerAt: i)
            }
            NotificationCenter.default.post(name: .modelsChanged, object: nil)
            RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.3))
            wc.window?.setContentSize(NSSize(width: 1240, height: 820))
            wc.window?.center()
            split.layoutSubtreeIfNeeded()
            guard split.bounds.width >= 1000 else {
                print("PROBE divider-drag: window too narrow (\(split.bounds.width))")
                fflush(stdout)
                exit(2)
            }
            let before = wc.sidebar.view.frame.width
            // Divider trails the sidebar pane (divider 0 when expanded),
            // then half the divider's own thickness.
            var c = NSPoint(x: before + split.dividerThickness / 2,
                            y: split.bounds.midY)
            c = split.convert(c, to: nil)
            NSApp.activate(ignoringOtherApps: true)
            wc.window?.makeKeyAndOrderFront(nil)
            RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.5))
            guard let win = wc.window else {
                print("PROBE divider-drag: no window")
                fflush(stdout)
                exit(2)
            }
            let wnum = win.windowNumber
            let t = ProcessInfo.processInfo.systemUptime
            var n = 9000
            func ev(_ type: NSEvent.EventType, _ pt: NSPoint, _ ts: TimeInterval) -> NSEvent? {
                n += 1
                return NSEvent.mouseEvent(with: type, location: pt, modifierFlags: [],
                                          timestamp: ts, windowNumber: wnum, context: nil,
                                          eventNumber: n, clickCount: 1,
                                          pressure: type == .leftMouseUp ? 0 : 1)
            }
            // Queue the whole gesture first; the tracking loop started by the
            // press below consumes it synchronously.
            var ts = t
            for step in [0.25, 0.5, 0.75, 1.0] as [CGFloat] {
                ts += 0.03
                if let e = ev(.leftMouseDragged, NSPoint(x: c.x + dx * step, y: c.y), ts) {
                    NSApp.postEvent(e, atStart: false)
                }
            }
            guard let up = ev(.leftMouseUp, NSPoint(x: c.x + dx, y: c.y), ts + 0.03),
                  let down = ev(.leftMouseDown, c, t) else {
                print("PROBE divider-drag: event alloc failed")
                fflush(stdout)
                exit(2)
            }
            NSApp.postEvent(up, atStart: false)
            // Direct dispatch: NSApp.sendEvent never reaches the split view's
            // tracking loop for synthetic events; mouseDown(with:) does, and
            // it runs the identical tracking code a physical drag uses.
            split.mouseDown(with: down)
            let after = wc.sidebar.view.frame.width
            let expected = min(360, max(220, before + dx))
            let pass = abs(after - expected) <= 2
            print("PROBE divider-drag dx=\(Int(dx)) before=\(before) after=\(after) expected=\(expected) result=\(pass ? "PASS" : "FAIL")")
            fflush(stdout)
            // Leave no trace: restore the saved width convention, let any
            // pending layout settle, then exit with the verdict.
            split.setPosition(Settings.shared.sidebarWidth, ofDividerAt: 0)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { exit(pass ? 0 : 1) }
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ s: NSApplication) -> Bool { true }
    func applicationWillTerminate(_ notification: Notification) {
        MCPHub.shared.stopAll()
        mainWindow?.shutdown()
    }

    @objc func openSettings(_ s: Any?) {
        mainWindow?.showSettings()
    }

    @objc func newSession(_ s: Any?) { mainWindow?.newSession() }
    @objc func deleteSession(_ s: Any?) { mainWindow?.deleteSelectedSession() }
    @objc func toggleSidebar(_ s: Any?) { mainWindow?.toggleSidebar() }
    @objc func toggleInspector(_ s: Any?) { mainWindow?.toggleInspector() }
    @objc func openAPIDocs(_ s: Any?) {
        if let url = URL(string: "https://api-docs.deepseek.com/") { NSWorkspace.shared.open(url) }
    }

    private func buildMenu() {
        let main = NSMenu()
        let appItem = NSMenuItem()
        // Standard app menu: same name as the window, plus Services and the
        // Hide trio every Mac app is expected to have.
        let appName = "DeepSeek Harness"
        let appMenu = NSMenu(title: appName)
        appMenu.addItem(withTitle: "About \(appName)", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        appMenu.addItem(.separator())
        let settingsItem = appMenu.addItem(withTitle: "Settings…", action: #selector(openSettings), keyEquivalent: ",")
        // Explicit targets: nil-targeted custom actions fail menu validation
        // (and their shortcuts die with them), leaving no in-window path to
        // the toggles. The Appearance items below already do this.
        settingsItem.target = self
        appMenu.addItem(.separator())
        let servicesMenu = NSMenu(title: "Services")
        let servicesItem = appMenu.addItem(withTitle: "Services", action: nil, keyEquivalent: "")
        servicesItem.submenu = servicesMenu
        NSApp.servicesMenu = servicesMenu
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Hide \(appName)", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        let hideOthers = appMenu.addItem(withTitle: "Hide Others", action: #selector(NSApplication.hideOtherApplications(_:)), keyEquivalent: "h")
        hideOthers.keyEquivalentModifierMask = [.command, .option]
        appMenu.addItem(withTitle: "Show All", action: #selector(NSApplication.unhideAllApplications(_:)), keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Quit \(appName)", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu
        main.addItem(appItem)

        let fileItem = NSMenuItem()
        let fileMenu = NSMenu(title: "File")
        let newItem = fileMenu.addItem(withTitle: "New Session", action: #selector(newSession), keyEquivalent: "n")
        newItem.target = self
        let deleteItem = fileMenu.addItem(withTitle: "Delete Session", action: #selector(deleteSession), keyEquivalent: "\u{7f}")
        deleteItem.target = self
        fileMenu.addItem(withTitle: "Close Window", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        fileItem.submenu = fileMenu
        main.addItem(fileItem)

        let editItem = NSMenuItem()
        let editMenu = NSMenu(title: "Edit")
        for (t, a, k) in [("Undo", #selector(UndoManager.undo), "z"),
                          ("Redo", #selector(UndoManager.redo), "Z"),
                          ("Cut", #selector(NSText.cut(_:)), "x"),
                          ("Copy", #selector(NSText.copy(_:)), "c"),
                          ("Paste", #selector(NSText.paste(_:)), "v"),
                          ("Select All", #selector(NSText.selectAll(_:)), "a")] as [(String, Selector, String)] {
            let i = NSMenuItem(title: t, action: a, keyEquivalent: k)
            editMenu.addItem(i)
        }
        editItem.submenu = editMenu
        main.addItem(editItem)

        let viewItem = NSMenuItem()
        let viewMenu = NSMenu(title: "View")
        let sidebarItem = NSMenuItem(title: "Toggle Sidebar", action: #selector(toggleSidebar), keyEquivalent: "s")
        sidebarItem.keyEquivalentModifierMask = [.command, .option]
        sidebarItem.target = self
        viewMenu.addItem(sidebarItem)
        let inspectorItem = viewMenu.addItem(withTitle: "Toggle Inspector", action: #selector(toggleInspector), keyEquivalent: "i")
        inspectorItem.keyEquivalentModifierMask = [.command, .option] // ⌥⌘I, Apple's Inspector convention
        inspectorItem.target = self
        let appearance = NSMenu(title: "Appearance")
        appearance.delegate = self
        for title in ["System", "Light", "Dark"] {
            let item = NSMenuItem(title: title, action: #selector(setAppearance(_:)), keyEquivalent: "")
            item.target = self
            appearance.addItem(item)
        }
        let appearanceItem = NSMenuItem(title: "Appearance", action: nil, keyEquivalent: "")
        appearanceItem.submenu = appearance; viewMenu.addItem(appearanceItem)
        viewItem.submenu = viewMenu
        main.addItem(viewItem)

        // Window menu: AppKit appends the open-window list once it is
        // registered as NSApp.windowsMenu.
        let windowItem = NSMenuItem()
        let windowMenu = NSMenu(title: "Window")
        windowMenu.addItem(withTitle: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        windowMenu.addItem(withTitle: "Zoom", action: #selector(NSWindow.performZoom(_:)), keyEquivalent: "")
        windowMenu.addItem(.separator())
        windowMenu.addItem(withTitle: "Bring All to Front", action: #selector(NSApplication.arrangeInFront(_:)), keyEquivalent: "")
        windowItem.submenu = windowMenu
        main.addItem(windowItem)
        NSApp.windowsMenu = windowMenu

        // Help menu: registering it gives the system menu-search field.
        let helpItem = NSMenuItem()
        let helpMenu = NSMenu(title: "Help")
        let docs = helpMenu.addItem(withTitle: "DeepSeek API Documentation", action: #selector(openAPIDocs), keyEquivalent: "")
        docs.target = self
        helpItem.submenu = helpMenu
        main.addItem(helpItem)
        NSApp.helpMenu = helpMenu

        NSApp.mainMenu = main
    }
    @objc private func setAppearance(_ item: NSMenuItem) {
        Settings.shared.appearance = item.title
        NSApp.appearance = item.title == "System" ? nil : NSAppearance(named: item.title == "Light" ? .aqua : .darkAqua)
        item.menu?.items.forEach { $0.state = $0.title == item.title ? .on : .off }
    }
    func menuNeedsUpdate(_ menu: NSMenu) {
        guard menu.title == "Appearance" else { return }
        menu.items.forEach { $0.state = $0.title == Settings.shared.appearance ? .on : .off }
    }
}

extension AppDelegate {
    /// Session files are encrypted with a key kept in the Keychain. Fetch it
    /// at launch (so any Keychain prompt appears now, not mid-conversation)
    /// and tell the user if conversations can't be opened or saved, rather
    /// than leaving them silently missing.
    func reportSessionStorageProblems(in window: NSWindow) {
        guard !Preview.enabled else { return }
        var keyError: Error?
        do { _ = try SessionCipher.key() } catch { keyError = error }
        let unreadable = SessionStore.shared.undecryptable.count
        guard keyError != nil || unreadable > 0 else { return }

        let alert = NSAlert()
        alert.alertStyle = .warning
        if unreadable > 0 {
            alert.messageText = unreadable == 1
                ? "1 conversation couldn't be opened"
                : "\(unreadable) conversations couldn't be opened"
            alert.informativeText = """
                Conversations are encrypted with a key stored in your Keychain. \
                DeepSeek Harness couldn't use that key: Keychain access was denied, \
                the Keychain is locked, or the key was removed.

                The files are kept unchanged. Allow Keychain access and relaunch \
                to try again.
                """
        } else {
            alert.messageText = "Conversations can't be saved"
            alert.informativeText = """
                Conversations are encrypted with a key stored in your Keychain, \
                and DeepSeek Harness couldn't access it (\(keyError.map { "\($0)" } ?? "unknown error")). \
                New messages stay in memory until you allow Keychain access; \
                they will be lost if you quit before then.
                """
        }
        alert.addButton(withTitle: "OK")
        if unreadable > 0 { alert.addButton(withTitle: "Show in Finder") }
        alert.beginSheetModal(for: window) { response in
            if response == .alertSecondButtonReturn {
                NSWorkspace.shared.activateFileViewerSelecting([Settings.sessionsDir])
            }
        }
    }
}
