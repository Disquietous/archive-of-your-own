import AppKit

final class MainWindowController: NSWindowController {
    convenience init(theme: AppTheme, appState: AppState) {
        let splitController = MainSplitViewController(theme: theme, appState: appState)
        let window = NSWindow(contentViewController: splitController)
        window.title = "AoYO"
        window.toolbarStyle = .unified
        window.titlebarAppearsTransparent = false
        window.styleMask.insert(.fullSizeContentView)
        window.setContentSize(NSSize(width: 1280, height: 860))
        window.center()
        window.setFrameAutosaveName("MainWindow")

        // An empty unified toolbar gives the standard full-height sidebar look.
        let toolbar = NSToolbar(identifier: "MainToolbar")
        toolbar.displayMode = .iconOnly
        window.toolbar = toolbar

        self.init(window: window)
    }
}
