import SwiftUI
import UserNotifications

@main
struct ArchiveApp: App {
    @Environment(\.scenePhase) private var scenePhase

    @State private var theme = AppTheme()
    @State private var appState: AppState
    @State private var models: AppModels
    @State private var nav = NavigationState()

    init() {
        let appState = AppState()
        _appState = State(initialValue: appState)
        _models = State(initialValue: AppModels(appState: appState))
        Self.retireBackgroundCheck()
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
            .modifier(TextSizeRange())
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
                    .modifier(TextSizeRange())
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
        // swiftlint:disable redundant_discardable_let
        let _ = bridge.isInitialized
        let _ = bridge.showingRecoveryKey
        let _ = bridge.hasDbPassword
        let _ = bridge.torHasConnectedOnce
        // swiftlint:enable redundant_discardable_let
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
        case .background:
            appState.didEnterBackground()
            // iOS suspends the app shortly: end works crawls now so they
            // land in a clean "Stopped — Resume" state instead of dying
            // mid-request.
            if models.author.isLoadingWorks { models.author.cancelWorksRefresh() }
            if models.subscriptionWorks.isLoading { models.subscriptionWorks.cancelRefresh() }
        case .active: appState.didBecomeActive()
        default: break
        }
    }

    // MARK: - Retired background check

    /// New works reach the phone through a foreground check or a synced
    /// library; there is no background check, notification or app badge.
    /// Clears what an older build left behind: a badge number and
    /// delivered "works updated" notifications. (A task request it queued
    /// can't launch the app: the identifier is gone from Info.plist.)
    private static func retireBackgroundCheck() {
        let center = UNUserNotificationCenter.current()
        center.setBadgeCount(0)
        center.removeAllDeliveredNotifications()
        center.removeAllPendingNotificationRequests()
        UserDefaults.standard.removeObject(forKey: "backgroundCheckEnabled")
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
            .environment(models.tts)
            .preferredColorScheme(theme.preferredColorScheme)
    }
}

/// App chrome follows the system text size (custom fonts scale with the
/// body style) across the standard range. The accessibility sizes are
/// capped at the largest standard size: the chrome's fixed control heights
/// would clip beyond it. The reader's text has its own size setting.
struct TextSizeRange: ViewModifier {
    func body(content: Content) -> some View {
        content.dynamicTypeSize(...DynamicTypeSize.xxxLarge)
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
