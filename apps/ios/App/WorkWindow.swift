import SwiftUI
import UIKit

/// What a work window shows: one work open at a chapter. The value keys
/// the `WindowGroup(for:)` scene, so opening the same work again surfaces
/// its existing window instead of making a second one — the
/// one-reader-per-work rule the macOS `WorkWindowRegistry` enforces, here
/// for free from scene identity. iPad only; iPhone has no windows.
struct WorkWindowValue: Codable, Hashable {
    let workID: String
    let chapterIndex: Int
    var entireWork = false
}

extension WorkWindowValue {
    /// Whether this device can open a work in its own window.
    @MainActor
    static var isSupported: Bool {
        UIDevice.current.userInterfaceIdiom == .pad
            && UIApplication.shared.supportsMultipleScenes
    }
}

/// The root of a work window: the reader over its own navigation stack
/// (work detail, author profile and the like push inside the window) and
/// its own sheets. Shares the app's state and models; only navigation is
/// per-window. While the library is locked the window shows the unlock
/// screen — the scene, and with it the reader's place, comes back on the
/// next unlock (restore, not a fresh open: the reader resumes from the
/// saved progress).
struct WorkWindowRootView: View {
    @Environment(AppTheme.self) private var theme
    @Environment(AppState.self) private var state

    let value: WorkWindowValue

    @State private var nav = NavigationState()

    var body: some View {
        let bridge = state.bridge
        let _ = bridge.isInitialized
        let _ = bridge.hasDbPassword
        switch bridge.launchState {
        case .ready:
            NavigationStack(path: $nav.libraryPath) {
                ReaderView(workID: value.workID, chapterIndex: value.chapterIndex,
                           entireWork: value.entireWork)
                    .navigationDestination(for: AppDestination.self, destination: AppScreens.destination)
            }
            .environment(nav)
            .tint(theme.accent)
            .appSheets()
            .task(id: value.workID) {
                // A window can be restored before the work's row is in the
                // session map (a cold launch straight into this scene).
                if state.work(byID: value.workID) == nil {
                    await state.fetchWorkMetadata(value.workID)
                }
            }
        case .locked:
            DatabaseUnlockScreen()
        case .firstLaunch:
            DatabaseSetupScreen()
        case .autoUnlock, .connectingTor:
            Color(theme.bg)
                .ignoresSafeArea()
        }
    }
}
