import AppKit
import SwiftUI

final class MainSplitViewController: NSSplitViewController {
    private let theme: AppTheme
    private let appState: AppState
    private let model: MacAppModel

    private var sidebarItem: NSSplitViewItem!
    private var listItem: NSSplitViewItem!
    private var immersiveApplied = false

    init(theme: AppTheme, appState: AppState, model: MacAppModel) {
        self.theme = theme
        self.appState = appState
        self.model = model
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        splitView.dividerStyle = .thin

        let sidebarController = NSHostingController(
            rootView: SidebarView(theme: theme, appState: appState, model: model)
        )
        // Plain item, not sidebarWithViewController: the design's sidebar is an
        // opaque tinted surface, not the system translucent material.
        sidebarItem = NSSplitViewItem(viewController: sidebarController)
        sidebarItem.minimumThickness = 248
        sidebarItem.maximumThickness = 248
        sidebarItem.canCollapse = true
        addSplitViewItem(sidebarItem)

        let listController = ListPaneViewController(theme: theme, model: model)
        listItem = NSSplitViewItem(viewController: listController)
        listItem.minimumThickness = 384
        listItem.maximumThickness = 384
        listItem.canCollapse = true
        addSplitViewItem(listItem)

        let readController = ReadPaneViewController(theme: theme, appState: appState, model: model)
        let readerItem = NSSplitViewItem(viewController: readController)
        readerItem.minimumThickness = 400
        addSplitViewItem(readerItem)

        ObservationRelay.track { [weak self] in
            guard let self else { return }
            let immersive = self.model.immersive
            DispatchQueue.main.async { self.applyImmersive(immersive) }
        }
    }

    private func applyImmersive(_ immersive: Bool) {
        guard immersive != immersiveApplied else { return }
        immersiveApplied = immersive
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.32
            context.timingFunction = CAMediaTimingFunction(controlPoints: 0.4, 0, 0.2, 1)
            sidebarItem.animator().isCollapsed = immersive
            listItem.animator().isCollapsed = immersive
        }
    }

    // Esc exits immersive mode (popovers handle their own dismissal).
    override func cancelOperation(_ sender: Any?) {
        if model.immersive {
            model.immersive = false
        }
    }
}
