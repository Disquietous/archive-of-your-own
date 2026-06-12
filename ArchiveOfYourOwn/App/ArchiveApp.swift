import SwiftUI
import BackgroundTasks

@main
struct ArchiveApp: App {
    @State private var theme = AppTheme()
    @State private var appState = AppState()
    @State private var nav = NavigationState()

    private static let subscriptionCheckIdentifier = "com.archiveofyourown.reader.subscriptioncheck"

    init() {
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
            let bridge = appState.bridge
            let _ = bridge.isInitialized
            let _ = bridge.showingRecoveryKey
            let _ = bridge.hasDbPassword
            let _ = bridge.torHasConnectedOnce
            switch bridge.launchState {
            case .ready:
                ContentView()
                    .environment(theme)
                    .environment(appState)
                    .environment(nav)
                    .preferredColorScheme(theme.preferredColorScheme)
                    .animation(.easeInOut(duration: 0.4), value: theme.activeTheme.id)
                    .onAppear {
                        appState.loadPersistedState()
                        Self.scheduleSubscriptionCheck()
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
    }

    // MARK: - Background Task

    static func scheduleSubscriptionCheck() {
        let request = BGProcessingTaskRequest(identifier: subscriptionCheckIdentifier)
        request.earliestBeginDate = Date(timeIntervalSinceNow: 2 * 60 * 60)
        request.requiresNetworkConnectivity = true
        request.requiresExternalPower = false
        try? BGTaskScheduler.shared.submit(request)
    }

    private static func handleSubscriptionCheck(_ task: BGProcessingTask, appState: AppState) {
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
