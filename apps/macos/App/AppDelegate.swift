import AppKit
import UserNotifications

final class AppDelegate: NSObject, NSApplicationDelegate {
    let theme = AppTheme()
    let appState = AppState()
    lazy var model = MacAppModel(appState: appState)

    private var mainWindowController: MainWindowController?
    private var settingsWindowController: SettingsWindowController?
    private var requestLogWindowController: RequestLogWindowController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        MacFont.scale = CGFloat(theme.uiFontScale)
        buildMainMenu()

        // What's New: notify when a background check finds updates, and keep
        // the dock badge on the unviewed count.
        UNUserNotificationCenter.current().delegate = self
        appState.onNewWorksFound = { [weak self] count in
            self?.notifyNewWorks(count)
        }
        ObservationRelay.track { [weak self] in
            guard let self else { return }
            let count = appState.newWorkIDs.count
            DispatchQueue.main.async {
                NSApp.dockTile.badgeLabel = count > 0 ? "\(count)" : nil
            }
        }
        // Database creation/unlock is handled by the launch gate — first
        // launch shows Protect Your Library, a password-protected library
        // shows the unlock screen.
        let controller = MainWindowController(theme: theme, appState: appState, model: model)
        controller.showWindow(nil)
        mainWindowController = controller
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    @objc private func openSettings() {
        if settingsWindowController == nil {
            settingsWindowController = SettingsWindowController(theme: theme, appState: appState, model: model)
        }
        settingsWindowController?.show()
    }

    @objc private func openRequestLog() {
        if requestLogWindowController == nil {
            requestLogWindowController = RequestLogWindowController(theme: theme, appState: appState)
        }
        requestLogWindowController?.show()
    }

    // MARK: - Go menu

    /// Sidebar sections in Go-menu order; index = menu item tag, ⌘1–⌘9, ⌘0.
    private static let goSections: [(title: String, section: MacAppModel.Section, key: String)] = [
        ("Currently Reading", .reading, "1"),
        ("Search", .search, "2"),
        ("History", .history, "3"),
        ("Fandoms", .fandoms, "4"),
        ("Authors", .authors, "5"),
        ("Browse", .browse, "6"),
        ("What\u{2019}s New", .whatsNew, "7"),
        ("Subscriptions", .subscriptions, ""),
        ("Inbox", .inbox, "8"),
        ("Bookmarks", .bookmarks, "9"),
        ("Offline", .downloads, "0"),
    ]

    @objc private func goSectionMenu(_ sender: NSMenuItem) {
        guard sender.tag >= 0, sender.tag < Self.goSections.count else { return }
        model.goSection(Self.goSections[sender.tag].section)
    }

    @objc private func promptOpenAO3URL() {
        let alert = NSAlert()
        alert.messageText = "Open AO3 URL"
        alert.informativeText = "Paste a link to a work, author, or series."
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 340, height: 24))
        field.placeholderString = "https://archiveofourown.org/works/…"
        alert.accessoryView = field
        alert.addButton(withTitle: "Open")
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = field
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        if !model.openAO3URL(field.stringValue) {
            let failed = NSAlert()
            failed.alertStyle = .warning
            failed.messageText = "Couldn’t open that link"
            failed.informativeText = "Paste an archiveofourown.org work, author, or series URL."
            failed.runModal()
        }
    }

    // MARK: - EPUB export

    @objc private func exportSelectedWork() {
        guard let work = model.selectedWork else { return }
        EpubExporter.export(work: work, appState: appState)
    }

    /// Grey out Export when there's no exportable (real, numeric-ID) selection.
    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        if menuItem.action == #selector(exportSelectedWork) {
            guard let work = model.selectedWork, UInt64(work.id) != nil else { return false }
            return true
        }
        return true
    }

    // MARK: - What's New notifications

    private func notifyNewWorks(_ count: Int) {
        // The user is looking at the app — the What's New badge is enough.
        guard !NSApp.isActive else { return }
        let center = UNUserNotificationCenter.current()
        center.requestAuthorization(options: [.alert, .badge]) { granted, _ in
            guard granted else { return }
            let content = UNMutableNotificationContent()
            content.title = count == 1 ? "1 work updated" : "\(count) works updated"
            content.body = "Works you follow have new chapters waiting."
            let request = UNNotificationRequest(identifier: "whats-new-\(UUID().uuidString)",
                                                content: content, trigger: nil)
            center.add(request)
        }
    }

    // MARK: - Menu

    private func buildMainMenu() {
        let mainMenu = NSMenu()

        // App menu
        let appMenuItem = NSMenuItem()
        let appMenu = NSMenu()
        let appName = ProcessInfo.processInfo.processName
        appMenu.addItem(withTitle: "About \(appName)",
                        action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)),
                        keyEquivalent: "")
        appMenu.addItem(.separator())
        let settingsItem = NSMenuItem(title: "Settings…", action: #selector(openSettings), keyEquivalent: ",")
        settingsItem.target = self
        appMenu.addItem(settingsItem)
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
        mainMenu.addItem(appMenuItem)

        // File menu
        let fileMenuItem = NSMenuItem()
        let fileMenu = NSMenu(title: "File")
        let exportItem = NSMenuItem(title: "Export as EPUB…", action: #selector(exportSelectedWork), keyEquivalent: "e")
        exportItem.keyEquivalentModifierMask = [.command, .shift]
        exportItem.target = self
        fileMenu.addItem(exportItem)
        fileMenuItem.submenu = fileMenu
        mainMenu.addItem(fileMenuItem)

        // Edit menu (copy/select-all/find work via responder chain in NSTextView)
        let editMenuItem = NSMenuItem()
        let editMenu = NSMenu(title: "Edit")
        editMenu.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editMenu.addItem(.separator())
        let findItem = NSMenuItem(title: "Find…", action: #selector(NSTextView.performFindPanelAction(_:)), keyEquivalent: "f")
        findItem.tag = NSTextFinder.Action.showFindInterface.rawValue
        editMenu.addItem(findItem)
        editMenuItem.submenu = editMenu
        mainMenu.addItem(editMenuItem)

        // Go menu — keyboard access to every sidebar section + URL routing
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
        mainMenu.addItem(goMenuItem)

        // View menu (sidebar toggle etc. via responder chain)
        let viewMenuItem = NSMenuItem()
        let viewMenu = NSMenu(title: "View")
        let toggleSidebar = NSMenuItem(title: "Toggle Sidebar",
                                       action: #selector(NSSplitViewController.toggleSidebar(_:)),
                                       keyEquivalent: "s")
        toggleSidebar.keyEquivalentModifierMask = [.command, .control]
        viewMenu.addItem(toggleSidebar)
        viewMenu.addItem(.separator())
        let requestLog = NSMenuItem(title: "Request Log", action: #selector(openRequestLog), keyEquivalent: "l")
        requestLog.keyEquivalentModifierMask = [.command, .option]
        requestLog.target = self
        viewMenu.addItem(requestLog)
        viewMenuItem.submenu = viewMenu
        mainMenu.addItem(viewMenuItem)

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
}

extension AppDelegate: UNUserNotificationCenterDelegate {
    /// Clicking the notification brings the app forward on What's New.
    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                didReceive response: UNNotificationResponse,
                                withCompletionHandler completionHandler: @escaping () -> Void) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            NSApp.activate(ignoringOtherApps: true)
            model.goSection(.whatsNew)
        }
        completionHandler()
    }
}
