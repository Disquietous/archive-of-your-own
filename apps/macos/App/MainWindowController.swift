import AppKit

final class MainWindowController: NSWindowController {
    convenience init(theme: AppTheme, appState: AppState, model: MacAppModel) {
        let splitController = MainSplitViewController(theme: theme, appState: appState, model: model)
        let window = NSWindow(contentViewController: splitController)
        window.title = "AoYO"
        // Panes draw their own 52px toolbars (per the design); the system
        // titlebar is hidden and the traffic lights float over the sidebar head.
        window.styleMask.insert(.fullSizeContentView)
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.setContentSize(NSSize(width: 1280, height: 820))
        window.minSize = NSSize(width: 1000, height: 600)
        window.center()
        window.setFrameAutosaveName("MainWindow")

        self.init(window: window)
    }
}
