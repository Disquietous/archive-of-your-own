import AppKit
import UserNotifications

final class AppDelegate: NSObject, NSApplicationDelegate {
    let theme = AppTheme()
    let appState = AppState()
    lazy var model = MacAppModel(appState: appState)

    private var mainWindowController: MainWindowController?
    private var settingsWindowController: SettingsWindowController?
    private var requestLogWindowController: RequestLogWindowController?
    private var debugLogWindowController: DebugLogWindowController?

    // Auto-lock: every in-app event stamps lastActivity; a coarse timer
    // compares the idle span against the user's setting.
    private var activityMonitor: Any?
    private var idleCheckTimer: Timer?
    private var lastActivity = Date()

    func applicationDidFinishLaunching(_ notification: Notification) {
        MacFont.scale = CGFloat(theme.uiFontScale)
        buildMainMenu()

        // What's New: notify when a background check finds updates, and keep
        // the dock badge on the unviewed count.
        UNUserNotificationCenter.current().delegate = self
        // Ask for notification permission now, at a predictable moment —
        // requesting inside notifyNewWorks made the system prompt appear at
        // whatever arbitrary time the first background check found updates.
        // Alert-only: the dock badge is drawn manually from newWorkIDs below,
        // so the UN badge would be a second, competing badge mechanism.
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert]) { _, _ in }
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

        setupAutoLock()
        setupScrollShortcuts()
    }

    // MARK: - ⌘↑ / ⌘↓ jump-to-top / jump-to-bottom

    private var scrollShortcutMonitor: Any?
    private weak var lastClickedScrollView: NSScrollView?

    /// One app-wide handler instead of per-component overrides: ⌘↑ and ⌘↓
    /// scroll a component to its top or bottom. Covers AppKit tables, the
    /// TextKit reader, and SwiftUI-hosted ScrollViews alike, since all of
    /// them sit in an NSScrollView. Targeting follows the system's
    /// scroll-under-pointer convention — SwiftUI content never becomes
    /// first responder, so keyboard focus alone would leave the list pane
    /// permanently capturing the shortcut.
    private func setupScrollShortcuts() {
        scrollShortcutMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .leftMouseDown]) { [weak self] event in
            guard let self else { return event }
            if event.type == .leftMouseDown {
                // Remember which scrolling component was last clicked —
                // the fallback target when the pointer has since moved
                // somewhere without one.
                if let window = event.window, let content = window.contentView {
                    let point = content.convert(event.locationInWindow, from: nil)
                    if let hit = content.hitTest(point),
                       let scrollView = enclosingScrollView(of: hit) {
                        lastClickedScrollView = scrollView
                    }
                }
                return event
            }
            guard event.keyCode == 126 || event.keyCode == 125 else { return event }
            let mods = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
                .subtracting([.numericPad, .function])
            guard mods == .command else { return event }
            // Leave editable fields alone — ⌘↑/⌘↓ move the insertion point
            // there, and hijacking that would scroll the pane behind them.
            if let editor = event.window?.firstResponder as? NSTextView, editor.isFieldEditor {
                return event
            }
            guard let scrollView = targetScrollView(for: event) else { return event }
            scroll(scrollView, toTop: event.keyCode == 126)
            return nil
        }
    }

    /// The scroll view the shortcut should act on, in priority order:
    /// under the pointer (matches how scroll wheels target), then the last
    /// one clicked, then the one enclosing the focused view.
    private func targetScrollView(for event: NSEvent) -> NSScrollView? {
        guard let window = event.window ?? NSApp.keyWindow else { return nil }
        if let content = window.contentView {
            let point = content.convert(window.mouseLocationOutsideOfEventStream, from: nil)
            if let hit = content.hitTest(point),
               let scrollView = enclosingScrollView(of: hit) {
                return scrollView
            }
        }
        if let clicked = lastClickedScrollView, clicked.window === window {
            return clicked
        }
        if let responder = window.firstResponder as? NSView,
           let scrollView = enclosingScrollView(of: responder) {
            return scrollView
        }
        return nil
    }

    private func enclosingScrollView(of view: NSView) -> NSScrollView? {
        var current: NSView? = view
        while let v = current {
            if let scrollView = v as? NSScrollView { return scrollView }
            current = v.superview
        }
        return nil
    }

    private func scroll(_ scrollView: NSScrollView, toTop: Bool) {
        guard let document = scrollView.documentView else { return }
        let clip = scrollView.contentView
        let maxY = max(0, document.frame.height - clip.bounds.height)
        let topIsZero = document.isFlipped
        let y = toTop == topIsZero ? 0 : maxY
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.15
            context.allowsImplicitAnimation = true
            clip.animator().setBoundsOrigin(NSPoint(x: clip.bounds.origin.x, y: y))
            scrollView.reflectScrolledClipView(clip)
        }
    }

    // MARK: - Auto-lock on idle

    private func setupAutoLock() {
        // Any user event inside the app counts as activity. mouseMoved is
        // included deliberately — reading without clicking is activity.
        let events: NSEvent.EventTypeMask = [
            .keyDown, .leftMouseDown, .rightMouseDown, .otherMouseDown,
            .scrollWheel, .mouseMoved, .leftMouseDragged, .magnify,
        ]
        activityMonitor = NSEvent.addLocalMonitorForEvents(matching: events) { [weak self] event in
            self?.lastActivity = Date()
            return event
        }
        // Coarse check: worst case adds ~15 s past the configured span,
        // which is fine for minute-granular timeouts.
        idleCheckTimer = Timer.scheduledTimer(withTimeInterval: 15, repeats: true) { [weak self] _ in
            self?.lockIfIdle()
        }
    }

    private func lockIfIdle() {
        let minutes = appState.autoLockMinutes
        guard minutes > 0,
              appState.bridge.isInitialized,
              appState.bridge.hasDbPassword,
              Date().timeIntervalSince(lastActivity) >= Double(minutes) * 60 else { return }
        appState.lockNow()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    func applicationWillTerminate(_ notification: Notification) {
        if appState.historyMode == .clearOnClose {
            appState.clearHistory()
        }
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

    @objc private func openDebugLog() {
        if debugLogWindowController == nil {
            debugLogWindowController = DebugLogWindowController(theme: theme, appState: appState)
        }
        debugLogWindowController?.show()
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
        ("Reading Lists", .readingLists, ""),
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
        // Authorization was requested at launch; just check it here.
        center.getNotificationSettings { settings in
            guard settings.authorizationStatus == .authorized else { return }
            let content = UNMutableNotificationContent()
            content.title = count == 1 ? "1 work updated" : "\(count) works updated"
            content.body = "Works you follow have new chapters waiting."
            let request = UNNotificationRequest(identifier: "whats-new-\(UUID().uuidString)",
                                                content: content, trigger: nil)
            center.add(request)
        }
    }

    // Secure state restoration is supported (macOS 14 logs a warning and
    // falls back to insecure restoration when this is absent).
    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool {
        true
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
        let debugLog = NSMenuItem(title: "Debug Log", action: #selector(openDebugLog), keyEquivalent: "d")
        debugLog.keyEquivalentModifierMask = [.command, .option]
        debugLog.target = self
        viewMenu.addItem(debugLog)
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
