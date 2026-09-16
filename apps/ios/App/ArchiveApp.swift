import SwiftUI
import BackgroundTasks
import UserNotifications

@main
struct ArchiveApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @Environment(\.scenePhase) private var scenePhase

    @State private var theme = AppTheme()
    @State private var appState: AppState
    @State private var models: AppModels
    @State private var nav = NavigationState()

    private static let subscriptionCheckIdentifier = "com.archiveofyourown.reader.subscriptioncheck"

    init() {
        let appState = AppState()
        _appState = State(initialValue: appState)
        _models = State(initialValue: AppModels(appState: appState))
        BGTaskScheduler.shared.register(
            forTaskWithIdentifier: Self.subscriptionCheckIdentifier,
            using: nil
        ) { [appState] task in
            guard let bgTask = task as? BGProcessingTask else {
                task.setTaskCompleted(success: false)
                return
            }
            Self.handleSubscriptionCheck(bgTask, appState: appState)
        }
    }

    var body: some Scene {
        WindowGroup {
            Group {
                if ProcessInfo.processInfo.arguments.contains("-screenshots") {
                    ScreenshotHarness()
                } else {
                    normalLaunchView
                }
            }
            .modifier(privacyCover)
            .onChange(of: scenePhase) { _, newPhase in
                handleScenePhase(newPhase)
            }
        }

        // A work in its own window (iPad, D3): the scene is keyed by the
        // work, so re-opening a work surfaces its window. The window
        // carries the same state and models; only navigation is its own.
        // Locking shows the unlock screen in every window; unlocking puts
        // the reader back where it was.
        WindowGroup(for: WorkWindowValue.self) { $value in
            if let value {
                WorkWindowRootView(value: value)
                    .modifier(sharedEnvironment)
                    .modifier(privacyCover)
            }
        }
    }

    /// Theme, state and the hoisted models — everything a root view
    /// needs besides its own `NavigationState`.
    private var sharedEnvironment: SharedEnvironmentModifier {
        SharedEnvironmentModifier(theme: theme, appState: appState, models: models)
    }

    /// Privacy cover: while inactive (app switcher, incoming call,
    /// Control Center) the snapshot the system keeps shows the theme
    /// background and nothing the user was reading.
    private var privacyCover: PrivacyCoverModifier {
        PrivacyCoverModifier(theme: theme, active: scenePhase == .active)
    }

    @ViewBuilder
    private var normalLaunchView: some View {
        let bridge = appState.bridge
        let _ = bridge.isInitialized
        let _ = bridge.showingRecoveryKey
        let _ = bridge.hasDbPassword
        let _ = bridge.torHasConnectedOnce
        switch bridge.launchState {
        case .ready:
            ContentView()
                .modifier(sharedEnvironment)
                .environment(nav)
                .animation(.easeInOut(duration: 0.4), value: theme.activeTheme.id)
                .onAppear {
                    appState.loadPersistedState()
                    models.loadPersisted()
                    // Library file swapped underneath the core (iCloud copy
                    // adopted, backup restored): reload the models' caches.
                    appState.onLibraryReplaced = { models.loadPersisted() }
                    installNewWorksHooks()
                    Self.updateBackgroundCheckSchedule(enabled: appState.backgroundCheckEnabled)
                }
                .onChange(of: appState.backgroundCheckEnabled) { _, enabled in
                    Self.updateBackgroundCheckSchedule(enabled: enabled)
                    if enabled { Self.requestNotificationPermission() }
                }
                .onChange(of: appState.newUnviewedWorkCount, initial: true) { _, count in
                    // No-op until the user has granted badge permission; the
                    // number is the same one the What's New surface shows.
                    UNUserNotificationCenter.current().setBadgeCount(count)
                }
        case .locked:
            DatabaseUnlockScreen()
                .environment(theme)
                .environment(appState)
                .preferredColorScheme(theme.preferredColorScheme)
        case .firstLaunch:
            DatabaseSetupScreen()
                .environment(theme)
                .environment(appState)
                .preferredColorScheme(theme.preferredColorScheme)
        case .autoUnlock:
            Color(theme.bg)
                .ignoresSafeArea()
                .onAppear {
                    _ = appState.bridge.open()
                }
        case .connectingTor:
            TorConnectingScreen()
                .environment(theme)
                .environment(appState)
                .preferredColorScheme(theme.preferredColorScheme)
        }
    }

    // MARK: - Lifecycle

    private func handleScenePhase(_ phase: ScenePhase) {
        switch phase {
        case .background: appState.didEnterBackground()
        case .active: appState.didBecomeActive()
        default: break
        }
    }

    // MARK: - New-works notification

    /// A completed check that added works to What's New posts a local
    /// notification when the app is not in front (a background run, or the
    /// user left mid-check); in the foreground the badge is enough. The
    /// notification tap lands on the Library tab.
    private func installNewWorksHooks() {
        appState.onNewWorksFound = { count in
            guard UIApplication.shared.applicationState != .active else { return }
            Self.postNewWorksNotification(count)
        }
        appDelegate.onOpenWhatsNew = { [nav] in
            nav.goHome()
            nav.openLibrarySection(.whatsNew)
        }
    }

    private static func requestNotificationPermission() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .badge]) { _, _ in }
    }

    private static func postNewWorksNotification(_ count: Int) {
        let center = UNUserNotificationCenter.current()
        center.getNotificationSettings { settings in
            guard settings.authorizationStatus == .authorized
                    || settings.authorizationStatus == .provisional else { return }
            let content = UNMutableNotificationContent()
            content.title = count == 1 ? "1 work updated" : "\(count) works updated"
            content.body = "Works you follow have new chapters waiting."
            content.threadIdentifier = "whats-new"
            let request = UNNotificationRequest(identifier: "whats-new-\(UUID().uuidString)",
                                                content: content, trigger: nil)
            center.add(request)
        }
    }

    // MARK: - Background Task (opt-in)

    private static func updateBackgroundCheckSchedule(enabled: Bool) {
        if enabled {
            scheduleSubscriptionCheck()
        } else {
            BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: subscriptionCheckIdentifier)
        }
    }

    static func scheduleSubscriptionCheck() {
        let request = BGProcessingTaskRequest(identifier: subscriptionCheckIdentifier)
        request.earliestBeginDate = Date(timeIntervalSinceNow: 2 * 60 * 60)
        request.requiresNetworkConnectivity = true
        request.requiresExternalPower = false
        try? BGTaskScheduler.shared.submit(request)
    }

    private static func handleSubscriptionCheck(_ task: BGProcessingTask, appState: AppState) {
        // The toggle may have been switched off after this run was queued.
        guard appState.backgroundCheckEnabled else {
            task.setTaskCompleted(success: true)
            return
        }
        let workItem = Task {
            // Connect Tor if needed
            let useTor = UserDefaults.standard.bool(forKey: "useTorByDefault")
            if useTor {
                await appState.connectTor()
            }

            await appState.checkSubscriptions()

            // Schedule next check
            scheduleSubscriptionCheck()
            task.setTaskCompleted(success: true)
        }

        task.expirationHandler = {
            workItem.cancel()
            task.setTaskCompleted(success: false)
        }
    }
}

// MARK: - App delegate (notification taps)

final class AppDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {
    /// Set by the app once the UI is up; routes a notification tap.
    var onOpenWhatsNew: (() -> Void)?

    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        UNUserNotificationCenter.current().delegate = self
        return true
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                didReceive response: UNNotificationResponse,
                                withCompletionHandler completionHandler: @escaping () -> Void) {
        DispatchQueue.main.async { [weak self] in
            self?.onOpenWhatsNew?()
        }
        completionHandler()
    }

    /// Foreground delivery: the badge already reflects the count, so a
    /// banner would only duplicate it.
    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([])
    }
}

/// Theme, state and the hoisted models for a root view — the main window
/// and each work window inject the same set.
struct SharedEnvironmentModifier: ViewModifier {
    let theme: AppTheme
    let appState: AppState
    let models: AppModels

    func body(content: Content) -> some View {
        content
            .environment(theme)
            .environment(appState)
            .environment(models.lists)
            .environment(models.follows)
            .environment(models.author)
            .environment(models.subscriptionWorks)
            .environment(models.search)
            .environment(models.ops)
            .preferredColorScheme(theme.preferredColorScheme)
    }
}

/// While a scene is inactive the system snapshot shows only the theme
/// background.
struct PrivacyCoverModifier: ViewModifier {
    let theme: AppTheme
    let active: Bool

    func body(content: Content) -> some View {
        content
            .overlay {
                if !active {
                    ThemeBackgroundView()
                        .environment(theme)
                        .transition(.opacity)
                }
            }
            .animation(.easeOut(duration: 0.15), value: active)
    }
}
