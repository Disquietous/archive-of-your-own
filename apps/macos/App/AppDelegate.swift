import AppKit
import UserNotifications

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let theme = AppTheme()
    let appState = AppState()
    lazy var model = MacAppModel(appState: appState, theme: theme)

    private var mainWindowController: MainWindowController?
    private var requestLogWindowController: RequestLogWindowController?
    private var debugLogWindowController: DebugLogWindowController?
    /// The What's New check monitor; the view reaches it to toggle
    /// keep-on-top, so it is not private.
    var whatsNewMonitor: WhatsNewMonitorWindowController?

    // Auto-lock: every in-app event stamps lastActivity; a coarse timer
    // compares the idle span against the user's setting.
    private var activityMonitor: Any?
    private var idleCheckTimer: Timer?
    private var lastActivity = Date()
    /// The iCloud conflict alert while it's up (sheet or modal).
    private var cloudConflictAlert: NSAlert?

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
        // A notification click macOS routed to another copy of the app (same
        // bundle ID, different path) lands here: that duplicate quits and
        // forwards the click.
        DistributedNotificationCenter.default().addObserver(
            forName: SingleInstance.showWhatsNewNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.showWhatsNewFromNotification() }
        }
        appState.onNewWorksFound = { [weak self] count in
            self?.notifyNewWorks(count)
        }
        // Another device's library turned up in iCloud: the user decides,
        // in a sheet on the main window (or a standalone alert when none).
        appState.cloudSync.presentConflict = { [weak self] conflict in
            self?.presentCloudConflict(conflict)
        }
        // A user-initiated subscription reload found subscriptions with no
        // follow: one "Follow All / Not Now" prompt for the whole set.
        ObservationRelay.track { [weak self] in
            guard let self, let pending = appState.pendingFollowAll, !pending.isEmpty else { return }
            DispatchQueue.main.async {
                self.appState.pendingFollowAll = nil
                self.presentFollowAll(pending)
            }
        }
        // Bell-menu notices show in the list pane's status bar; each clears
        // itself after a few seconds unless a newer one replaced it.
        ObservationRelay.track { [weak self] in
            guard let self, let notice = model.follows.notice else { return }
            DispatchQueue.main.asyncAfter(deadline: .now() + (notice.isError ? 8 : 5)) { [weak self] in
                guard let self, model.follows.notice == notice else { return }
                model.follows.clearNotice()
            }
        }
        // Launch found a What's New check overdue: warn, never auto-start —
        // and not before Tor (when enabled) is connected.
        ObservationRelay.track { [weak self] in
            guard let self, appState.showWhatsNewOverdue else { return }
            DispatchQueue.main.async {
                self.appState.whatsNewCheckOverdue = false
                self.presentWhatsNewOverdue()
            }
        }
        ObservationRelay.track { [weak self] in
            guard let self else { return }
            let count = appState.newUnviewedWorkCount
            DispatchQueue.main.async {
                NSApp.dockTile.badgeLabel = count > 0 ? "\(count)" : nil
            }
        }
        // Locking tears down the core; work windows would keep rendering
        // against a dead bridge, so they close with it — remembered, so the
        // unlock puts them back where they were, on what they were showing.
        // (Positions were flushed before the lock — see lockIfIdle.)
        ObservationRelay.track { [weak self] in
            guard let self else { return }
            let initialized = appState.bridge.isInitialized
            DispatchQueue.main.async {
                if initialized {
                    self.model.windows.restoreAfterUnlock()
                } else {
                    self.model.windows.suspendForLock()
                }
            }
        }
        // Database creation/unlock is handled by the launch gate — first
        // launch shows Protect Your Library, a password-protected library
        // shows the unlock screen.
        let controller = MainWindowController(theme: theme, appState: appState, model: model)
        controller.showWindow(nil)
        mainWindowController = controller

        // Closing the main window quits the app. The log viewers are
        // accessories to it — close them here so they can't hold the app
        // open past the last-window-closed termination rule.
        if let mainWindow = controller.window {
            NotificationCenter.default.addObserver(
                forName: NSWindow.willCloseNotification, object: mainWindow, queue: .main
            ) { [weak self] _ in
                // Delivered on the main queue (queue: .main above).
                MainActor.assumeIsolated {
                    self?.requestLogWindowController?.close()
                    self?.debugLogWindowController?.close()
                    self?.model.windows.closeAll()
                }
            }
        }

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
            // Scheduled on the main run loop, so this fires on the main thread.
            MainActor.assumeIsolated { self?.lockIfIdle() }
        }
    }

    private func lockIfIdle() {
        let minutes = appState.autoLockMinutes
        guard minutes > 0,
              appState.bridge.isInitialized,
              appState.bridge.hasDbPassword,
              Date().timeIntervalSince(lastActivity) >= Double(minutes) * 60 else { return }
        // Debounced scroll persists in every reader land before the
        // bridge goes away — after lock, saveProgress is a silent no-op.
        model.windows.flushAll()
        appState.lockNow()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    /// Called on every sync check that finds another device's copy: an
    /// alert already on screen stays (and comes forward); one that was
    /// lost (its window gone) is replaced.
    private func presentCloudConflict(_ conflict: CloudLibrarySync.Conflict) {
        if let shown = cloudConflictAlert, shown.window.isVisible {
            shown.window.orderFront(nil)
            return
        }
        let sync = appState.cloudSync
        let alert = NSAlert()
        cloudConflictAlert = alert
        alert.messageText = "iCloud has \(conflict.deviceName)'s library"
        let when = RelativeDateTimeFormatter().localizedString(for: conflict.writtenAt, relativeTo: Date())
        alert.informativeText = """
            It was updated \(when). Use it on this Mac (this Mac's library is kept as a backup), or replace the iCloud \
            copy with this Mac's library (the iCloud copy is kept as a backup).
            """
        alert.addButton(withTitle: "Use iCloud Copy")
        alert.addButton(withTitle: "Replace iCloud Copy")
        alert.addButton(withTitle: "Not Now")
        let handle: (NSApplication.ModalResponse) -> Void = { [weak self] response in
            if self?.cloudConflictAlert === alert { self?.cloudConflictAlert = nil }
            switch response {
            case .alertFirstButtonReturn: sync.resolve(.useCloudCopy)
            case .alertSecondButtonReturn: sync.resolve(.overwriteCloudCopy)
            default: sync.resolve(.notNow)
            }
        }
        if let window = mainWindowController?.window, window.isVisible {
            alert.beginSheetModal(for: window, completionHandler: handle)
        } else {
            handle(alert.runModal())
        }
    }

    private func presentFollowAll(_ subscriptions: [USubscription]) {
        let prompt = FollowModel.bulkFollowPrompt(for: subscriptions)
        let alert = NSAlert()
        alert.messageText = prompt.title
        alert.informativeText = prompt.message
        alert.addButton(withTitle: FollowModel.BulkFollowPrompt.acceptLabel)
        alert.addButton(withTitle: FollowModel.BulkFollowPrompt.declineLabel)
        let handle: (NSApplication.ModalResponse) -> Void = { [weak self] response in
            if response == .alertFirstButtonReturn {
                self?.model.follows.followAll(subscriptions)
            }
        }
        if let window = mainWindowController?.window, window.isVisible {
            alert.beginSheetModal(for: window, completionHandler: handle)
        } else {
            handle(alert.runModal())
        }
    }

    private func presentWhatsNewOverdue() {
        let alert = NSAlert()
        alert.messageText = "What’s New is out of date"
        alert.informativeText = "Some followed authors, works or series haven’t been checked in over 24 hours."
        alert.addButton(withTitle: "Check Now")
        alert.addButton(withTitle: "Later")
        let handle: (NSApplication.ModalResponse) -> Void = { [weak self] response in
            if response == .alertFirstButtonReturn {
                self?.appState.startWhatsNewCheck(all: false)
            }
        }
        if let window = mainWindowController?.window, window.isVisible {
            alert.beginSheetModal(for: window, completionHandler: handle)
        } else {
            handle(alert.runModal())
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        model.windows.flushAll()
        appState.cloudSync.flush()
        if appState.historyMode == .clearOnClose {
            appState.clearHistory()
        }
    }

    @objc func openRequestLog() {
        if requestLogWindowController == nil {
            let controller = RequestLogWindowController(theme: theme, appState: appState)
            requestLogWindowController = controller
            releaseOnClose(controller.window) { [weak self] in
                self?.requestLogWindowController = nil
            }
        }
        requestLogWindowController?.show()
    }

    @objc func openWhatsNewMonitor() {
        if whatsNewMonitor == nil {
            let controller = WhatsNewMonitorWindowController(theme: theme, appState: appState)
            whatsNewMonitor = controller
            releaseOnClose(controller.window) { [weak self] in
                self?.whatsNewMonitor = nil
            }
        }
        whatsNewMonitor?.show()
    }

    @objc func openDebugLog() {
        if debugLogWindowController == nil {
            let controller = DebugLogWindowController(theme: theme, appState: appState)
            debugLogWindowController = controller
            releaseOnClose(controller.window) { [weak self] in
                self?.debugLogWindowController = nil
            }
        }
        debugLogWindowController?.show()
    }

    /// The inspector windows poll the core on a live timer for as long as
    /// their view hierarchy exists, and a closed NSWindowController window
    /// is only hidden — drop our reference on close so the window, its
    /// SwiftUI views, and their timers actually deallocate.
    private func releaseOnClose(_ window: NSWindow?, _ release: @escaping () -> Void) {
        guard let window else { return }
        let token = ObserverToken()
        token.value = NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification, object: window, queue: .main
        ) { _ in
            if let observer = token.value { NotificationCenter.default.removeObserver(observer) }
            // Deallocating mid-close is unsafe — let the close finish first.
            DispatchQueue.main.async(execute: release)
        }
    }

    // MARK: - Go menu

    /// Sidebar sections in Go-menu order; index = menu item tag, ⌘1–⌘9, ⌘0.
    static let goSections: [(title: String, section: MacAppModel.Section, key: String)] = [
        ("Currently Reading", .reading, "1"),
        ("Search", .search, "2"),
        ("History", .history, "3"),
        ("Fandoms", .fandoms, "4"),
        ("Authors", .authors, "5"),
        ("What\u{2019}s New", .whatsNew, "7"),
        ("Subscriptions", .subscriptions, ""),
        ("Inbox", .inbox, "8"),
        ("Bookmarks", .bookmarks, "9"),
        ("Reading Lists", .readingLists, ""),
        ("Offline", .downloads, "0"),
    ]

    @objc func goSectionMenu(_ sender: NSMenuItem) {
        guard sender.tag >= 0, sender.tag < Self.goSections.count else { return }
        model.goSection(Self.goSections[sender.tag].section)
    }

    @objc func promptOpenAO3URL() {
        let alert = NSAlert()
        alert.messageText = "Open AO3 URL"
        alert.informativeText = "Paste an archiveofourown.org link. \(AO3Link.supportedSummary)"
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 340, height: 24))
        field.placeholderString = "https://archiveofourown.org/works/…"
        alert.accessoryView = field
        alert.addButton(withTitle: "Open")
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = field
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        if let problem = model.openAO3URL(field.stringValue) {
            Self.presentLinkFailure(problem)
        }
    }

    /// The one alert for a link the app can't open (⌘L or a drop).
    static func presentLinkFailure(_ problem: String) {
        let failed = NSAlert()
        failed.alertStyle = .warning
        failed.messageText = "Couldn’t open that link"
        failed.informativeText = "\(problem) \(AO3Link.supportedSummary)"
        failed.runModal()
    }

    // MARK: - EPUB export

    /// The work File-menu commands act on: the key window's work when
    /// that is a work window, else the main window's selection.
    private var exportableWork: Work? {
        if let controller = NSApp.keyWindow?.windowController as? WorkWindowController {
            return controller.work
        }
        return model.selectedWork
    }

    @objc func exportSelectedWork() {
        guard let work = exportableWork else { return }
        EpubExporter.export(work: work, appState: appState)
    }

    // MARK: - Discussion panel (View menu)

    /// The key window's discussion panel — the reading pane's or a work
    /// window's.
    private var keyDiscussion: DiscussionHost? {
        DiscussionHost.host(in: NSApp.keyWindow)
    }

    @objc func toggleDiscussion() {
        keyDiscussion?.toggleOpen()
    }

    @objc func toggleDiscussionExpanded() {
        keyDiscussion?.toggleExpanded()
    }

    /// Grey out Export when there's no exportable (real, numeric-ID)
    /// selection, and the discussion items where there's no work to discuss.
    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        if menuItem.action == #selector(exportSelectedWork) {
            guard let work = exportableWork, UInt64(work.id) != nil else { return false }
            return true
        }
        if menuItem.action == #selector(toggleDiscussion) || menuItem.action == #selector(toggleDiscussionExpanded) {
            guard let host = keyDiscussion, host.isAvailable else { return false }
            if menuItem.action == #selector(toggleDiscussion) {
                menuItem.title = host.isOpen ? "Hide Discussion" : "Show Discussion"
            } else {
                menuItem.title = host.isOpen && host.isExpanded ? "Show Reader Beside Discussion" : "Discussion Fills Reader"
            }
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
            UNUserNotificationCenter.current().add(request)
        }
    }

    // Secure state restoration is supported (macOS 14 logs a warning and
    // falls back to insecure restoration when this is absent).
    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool {
        true
    }
}

extension AppDelegate: UNUserNotificationCenterDelegate {
    /// Clicking the notification brings the app forward on What's New.
    /// UserNotifications calls this off the main thread — hop explicitly.
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
                                            didReceive response: UNNotificationResponse,
                                            withCompletionHandler completionHandler: @escaping () -> Void) {
        Task { @MainActor [weak self] in self?.showWhatsNewFromNotification() }
        completionHandler()
    }

    func showWhatsNewFromNotification() {
        NSApp.activate(ignoringOtherApps: true)
        model.goSection(.whatsNew)
    }
}

/// Holds a block observer's token so its own block can unregister it.
/// Written once before the observer can fire; read only on the main queue.
private final class ObserverToken: @unchecked Sendable {
    var value: NSObjectProtocol?
}
