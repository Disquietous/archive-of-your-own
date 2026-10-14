import AppKit

extension AppDelegate {
    // MARK: - Menu

    func buildMainMenu() {
        let mainMenu = NSMenu()

        // App menu
        mainMenu.addItem(makeAppMenuItem())

        // File menu
        mainMenu.addItem(makeFileMenuItem())

        // Edit menu — the full standard set, dispatched via the responder
        // chain. Text fields only honor ⌘X/⌘C/⌘V/⌘Z etc. when these items
        // exist in the main menu.
        mainMenu.addItem(makeEditMenuItem())

        // Go menu — keyboard access to every sidebar section + URL routing
        mainMenu.addItem(makeGoMenuItem())

        // View menu (sidebar toggle etc. via responder chain)
        mainMenu.addItem(makeViewMenuItem())

        // Window menu
        let windowMenuItem = NSMenuItem()
        let windowMenu = NSMenu(title: "Window")
        windowMenu.addItem(withTitle: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        windowMenu.addItem(withTitle: "Zoom", action: #selector(NSWindow.performZoom(_:)), keyEquivalent: "")
        windowMenuItem.submenu = windowMenu
        mainMenu.addItem(windowMenuItem)
        NSApp.windowsMenu = windowMenu

        NSApp.mainMenu = mainMenu
    }

    private func makeAppMenuItem() -> NSMenuItem {
        let appMenuItem = NSMenuItem()
        let appMenu = NSMenu()
        let appName = ProcessInfo.processInfo.processName
        appMenu.addItem(withTitle: "About \(appName)",
                        action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)),
                        keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Hide \(appName)",
                        action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        let hideOthers = NSMenuItem(title: "Hide Others",
                                    action: #selector(NSApplication.hideOtherApplications(_:)),
                                    keyEquivalent: "h")
        hideOthers.keyEquivalentModifierMask = [.command, .option]
        appMenu.addItem(hideOthers)
        appMenu.addItem(withTitle: "Show All",
                        action: #selector(NSApplication.unhideAllApplications(_:)), keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Quit \(appName)",
                        action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appMenuItem.submenu = appMenu
        return appMenuItem
    }

    private func makeFileMenuItem() -> NSMenuItem {
        let fileMenuItem = NSMenuItem()
        let fileMenu = NSMenu(title: "File")
        let exportItem = NSMenuItem(title: "Export as EPUB…", action: #selector(exportSelectedWork), keyEquivalent: "e")
        exportItem.keyEquivalentModifierMask = [.command, .shift]
        exportItem.target = self
        fileMenu.addItem(exportItem)
        fileMenuItem.submenu = fileMenu
        return fileMenuItem
    }

    private func makeEditMenuItem() -> NSMenuItem {
        let editMenuItem = NSMenuItem()
        let editMenu = NSMenu(title: "Edit")
        editMenu.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        let redoItem = NSMenuItem(title: "Redo", action: Selector(("redo:")), keyEquivalent: "z")
        redoItem.keyEquivalentModifierMask = [.command, .shift]
        editMenu.addItem(redoItem)
        editMenu.addItem(.separator())
        editMenu.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: "Delete", action: #selector(NSText.delete(_:)), keyEquivalent: "")
        editMenu.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editMenu.addItem(.separator())
        let findItem = NSMenuItem(title: "Find…", action: #selector(NSTextView.performFindPanelAction(_:)), keyEquivalent: "f")
        findItem.tag = NSTextFinder.Action.showFindInterface.rawValue
        editMenu.addItem(findItem)
        editMenuItem.submenu = editMenu
        return editMenuItem
    }

    private func makeGoMenuItem() -> NSMenuItem {
        let goMenuItem = NSMenuItem()
        let goMenu = NSMenu(title: "Go")
        let openURL = NSMenuItem(title: "Open AO3 URL…", action: #selector(promptOpenAO3URL), keyEquivalent: "l")
        openURL.target = self
        goMenu.addItem(openURL)
        goMenu.addItem(.separator())
        for (index, entry) in Self.goSections.enumerated() {
            let item = NSMenuItem(title: entry.title, action: #selector(goSectionMenu(_:)), keyEquivalent: entry.key)
            item.target = self
            item.tag = index
            goMenu.addItem(item)
        }
        goMenuItem.submenu = goMenu
        return goMenuItem
    }

    private func makeViewMenuItem() -> NSMenuItem {
        let viewMenuItem = NSMenuItem()
        let viewMenu = NSMenu(title: "View")
        let toggleSidebar = NSMenuItem(title: "Toggle Sidebar",
                                       action: #selector(NSSplitViewController.toggleSidebar(_:)),
                                       keyEquivalent: "s")
        toggleSidebar.keyEquivalentModifierMask = [.command, .control]
        viewMenu.addItem(toggleSidebar)
        viewMenu.addItem(.separator())
        let discussion = NSMenuItem(title: "Show Discussion", action: #selector(toggleDiscussion), keyEquivalent: "c")
        discussion.keyEquivalentModifierMask = [.command, .option]
        discussion.target = self
        viewMenu.addItem(discussion)
        let fill = NSMenuItem(title: "Discussion Fills Reader", action: #selector(toggleDiscussionExpanded),
                              keyEquivalent: "c")
        fill.keyEquivalentModifierMask = [.command, .option, .shift]
        fill.target = self
        viewMenu.addItem(fill)
        viewMenu.addItem(.separator())
        let monitor = NSMenuItem(title: "What's New Check…", action: #selector(openWhatsNewMonitor), keyEquivalent: "u")
        monitor.keyEquivalentModifierMask = [.command, .option]
        monitor.target = self
        viewMenu.addItem(monitor)
        // Troubleshooting tools, grouped (Settings › Diagnostics holds
        // their retention and timeout settings).
        let diagnosticsMenu = NSMenu(title: "Diagnostics")
        let requestLog = NSMenuItem(title: "Request Log", action: #selector(openRequestLog), keyEquivalent: "l")
        requestLog.keyEquivalentModifierMask = [.command, .option]
        requestLog.target = self
        diagnosticsMenu.addItem(requestLog)
        let debugLog = NSMenuItem(title: "Debug Log", action: #selector(openDebugLog), keyEquivalent: "d")
        debugLog.keyEquivalentModifierMask = [.command, .option]
        debugLog.target = self
        diagnosticsMenu.addItem(debugLog)
        let diagnostics = NSMenuItem(title: "Diagnostics", action: nil, keyEquivalent: "")
        diagnostics.submenu = diagnosticsMenu
        viewMenu.addItem(diagnostics)
        viewMenuItem.submenu = viewMenu
        return viewMenuItem
    }
}
