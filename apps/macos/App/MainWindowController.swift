import AppKit
import SwiftUI

final class MainWindowController: NSWindowController {
    private let theme: AppTheme
    private let appState: AppState
    private let model: MacAppModel

    private var splitController: MainSplitViewController?
    private var showingGate: Bool?
    private var torAutoStarted = false

    init(theme: AppTheme, appState: AppState, model: MacAppModel) {
        self.theme = theme
        self.appState = appState
        self.model = model

        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1280, height: 820),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                              backing: .buffered, defer: false)
        window.title = "AoYO"
        // Panes draw their own 52px toolbars (per the design); the system
        // titlebar is hidden and the traffic lights float over the sidebar head.
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.minSize = NSSize(width: 1000, height: 600)
        window.center()
        window.setFrameAutosaveName("MainWindow")
        super.init(window: window)

        // Route between the launch gate (database setup / unlock) and the
        // three-pane app based on the bridge's launch state.
        ObservationRelay.track { [weak self] in
            guard let self else { return }
            let bridge = appState.bridge
            let needsGate = !bridge.isInitialized || bridge.showingRecoveryKey
            DispatchQueue.main.async { self.apply(gate: needsGate) }
        }
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    private func apply(gate: Bool) {
        guard gate != showingGate, let window else { return }
        showingGate = gate
        let frame = window.frame
        if gate {
            window.contentViewController = NSHostingController(
                rootView: LaunchGateView(theme: theme, appState: appState))
        } else {
            let firstShow = splitController == nil
            if firstShow {
                splitController = MainSplitViewController(theme: theme, appState: appState, model: model)
            }
            window.contentViewController = splitController
            if firstShow {
                // Same startup sequence as iOS ContentView.onAppear, then
                // kick the initial section load (iOS does this via .task).
                appState.loadPersistedState()
                model.goSection(model.section)
            }
            autoConnectTorIfEnabled()
        }
        window.setFrame(frame, display: true)
    }

    private func autoConnectTorIfEnabled() {
        guard !torAutoStarted,
              UserDefaults.standard.bool(forKey: "useTorByDefault"),
              !appState.torStatus.isConnected else { return }
        torAutoStarted = true
        Task { await appState.connectTor() }
    }
}
