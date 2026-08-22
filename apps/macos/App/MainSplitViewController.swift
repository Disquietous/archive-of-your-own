import AppKit
import SwiftUI

final class MainSplitViewController: NSSplitViewController {
    private let theme: AppTheme
    private let appState: AppState
    private let model: MacAppModel

    private var sidebarItem: NSSplitViewItem!
    private var listItem: NSSplitViewItem!
    private var sidebarCollapsedApplied = false
    private var listCollapsedApplied = false

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

        let listController = ListPaneViewController(theme: theme, appState: appState, model: model)
        listItem = NSSplitViewItem(viewController: listController)
        listItem.minimumThickness = 384
        listItem.maximumThickness = 384
        listItem.canCollapse = true
        addSplitViewItem(listItem)

        let readController = ReadPaneViewController(theme: theme, appState: appState, model: model)
        let readerItem = NSSplitViewItem(viewController: readController)
        readerItem.minimumThickness = 400
        readerItem.holdingPriority = .defaultLow
        addSplitViewItem(readerItem)

        ObservationRelay.track { [weak self] in
            guard let self else { return }
            let immersive = self.model.immersive
            // Search and Settings span the reading pane full-width: the
            // middle pane has nothing to show for either.
            let hideList = immersive || self.model.section == .search
                || self.model.section == .settings
            // Immersive toggles slide — a deliberate reading-mode
            // transition. Section-driven changes snap: the merged
            // search/settings layout must appear whole, never showing
            // the list pane mid-collapse.
            let animated = immersive != self.sidebarCollapsedApplied
            // Applied in this same main-queue pass: deferring even one
            // hop lands past the frame commit, painting the new pane
            // content while the stale list pane is still on screen.
            self.applyCollapse(sidebar: immersive, list: hideList, animated: animated)
        }
    }

    private func applyCollapse(sidebar: Bool, list: Bool, animated: Bool) {
        guard sidebar != sidebarCollapsedApplied || list != listCollapsedApplied else { return }
        sidebarCollapsedApplied = sidebar
        listCollapsedApplied = list
        guard animated else {
            sidebarItem.isCollapsed = sidebar
            listItem.isCollapsed = list
            return
        }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.32
            context.timingFunction = CAMediaTimingFunction(controlPoints: 0.4, 0, 0.2, 1)
            sidebarItem.animator().isCollapsed = sidebar
            listItem.animator().isCollapsed = list
        }
    }

    // Esc exits immersive mode (popovers handle their own dismissal).
    override func cancelOperation(_ sender: Any?) {
        if model.immersive {
            model.immersive = false
        }
    }
}
