import AppKit
import SwiftUI

/// The window's top-level split: the main sidebar beside the content area.
final class MainSplitViewController: NSSplitViewController {
    private let theme: AppTheme
    private let appState: AppState
    private let model: MacAppModel

    private var sidebarItem: NSSplitViewItem!
    private var sidebarCollapsedApplied = false

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

        let content = ContentAreaViewController(theme: theme, appState: appState, model: model)
        let contentItem = NSSplitViewItem(viewController: content)
        contentItem.minimumThickness = 400
        contentItem.holdingPriority = .defaultLow
        addSplitViewItem(contentItem)

        ObservationRelay.track { [weak self] in
            guard let self else { return }
            self.applyCollapse(sidebar: self.model.immersive)
        }
    }

    /// Immersive toggles slide — a deliberate reading-mode transition.
    private func applyCollapse(sidebar: Bool) {
        guard sidebar != sidebarCollapsedApplied else { return }
        sidebarCollapsedApplied = sidebar
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.32
            context.timingFunction = CAMediaTimingFunction(controlPoints: 0.4, 0, 0.2, 1)
            sidebarItem.animator().isCollapsed = sidebar
        }
    }

    // Esc exits immersive mode (popovers handle their own dismissal).
    override func cancelOperation(_ sender: Any?) {
        if model.immersive {
            model.exitImmersive()
        }
    }
}

/// Everything right of the main sidebar: the list and reading panes, and —
/// while the Sources area is up — the source tabs across their top and the
/// selected source's sidebar down their left. The panes are the area's
/// content panel, so a source's options render exactly as any section does.
final class ContentAreaViewController: NSViewController {
    private let theme: AppTheme
    private let appState: AppState
    private let model: MacAppModel

    private let panes: PanesSplitViewController
    private var tabBar: NSView!
    private var sourceSidebar: NSView!
    private var emptyPanel: NSView!
    private var tabBarHeight: NSLayoutConstraint!
    private var sourceSidebarWidth: NSLayoutConstraint!

    init(theme: AppTheme, appState: AppState, model: MacAppModel) {
        self.theme = theme
        self.appState = appState
        self.model = model
        self.panes = PanesSplitViewController(theme: theme, appState: appState, model: model)
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override func loadView() {
        view = NSView()
    }

    override func viewDidLoad() {
        super.viewDidLoad()

        tabBar = Self.host(SourceAreaTabBar(theme: theme, model: model))
        sourceSidebar = Self.host(SourceSidebarView(theme: theme, appState: appState, model: model))
        emptyPanel = Self.host(SourceEmptyPanel(theme: theme, model: model))

        addChild(panes)
        let panesView = panes.view
        panesView.translatesAutoresizingMaskIntoConstraints = false
        for subview in [panesView, emptyPanel!, sourceSidebar!, tabBar!] {
            view.addSubview(subview)
        }

        tabBarHeight = tabBar.heightAnchor.constraint(equalToConstant: 0)
        sourceSidebarWidth = sourceSidebar.widthAnchor.constraint(equalToConstant: 0)
        NSLayoutConstraint.activate([
            tabBar.topAnchor.constraint(equalTo: view.topAnchor),
            tabBar.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            tabBar.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            tabBarHeight,

            sourceSidebar.topAnchor.constraint(equalTo: tabBar.bottomAnchor),
            sourceSidebar.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            sourceSidebar.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            sourceSidebarWidth,

            panesView.topAnchor.constraint(equalTo: tabBar.bottomAnchor),
            panesView.leadingAnchor.constraint(equalTo: sourceSidebar.trailingAnchor),
            panesView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            panesView.bottomAnchor.constraint(equalTo: view.bottomAnchor),

            emptyPanel.topAnchor.constraint(equalTo: panesView.topAnchor),
            emptyPanel.leadingAnchor.constraint(equalTo: panesView.leadingAnchor),
            emptyPanel.trailingAnchor.constraint(equalTo: panesView.trailingAnchor),
            emptyPanel.bottomAnchor.constraint(equalTo: panesView.bottomAnchor),
        ])

        ObservationRelay.track { [weak self] in
            guard let self else { return }
            // Immersive reading takes the whole window; the area's chrome
            // returns with the sidebar.
            let shown = self.model.sourcesShown && !self.model.immersive
            let empty = shown && !self.model.sourceTabHasContent
            self.apply(shown: shown, empty: empty)
        }
    }

    private func apply(shown: Bool, empty: Bool) {
        tabBarHeight.constant = shown ? SourceAreaTabBar.height : 0
        sourceSidebarWidth.constant = shown ? SourceSidebarView.width : 0
        tabBar.isHidden = !shown
        sourceSidebar.isHidden = !shown
        emptyPanel.isHidden = !empty
        // A hidden pane must not take clicks or keys meant for the panel
        // covering it.
        panes.view.isHidden = empty
    }

    /// A SwiftUI view sized only by its constraints.
    private static func host(_ root: some View) -> NSView {
        let hosting = NSHostingView(rootView: root)
        hosting.sizingOptions = []
        hosting.translatesAutoresizingMaskIntoConstraints = false
        return hosting
    }
}

/// The list pane beside the reading pane.
final class PanesSplitViewController: NSSplitViewController {
    private let theme: AppTheme
    private let appState: AppState
    private let model: MacAppModel

    private var listItem: NSSplitViewItem!
    private var listCollapsedApplied = false
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
            let animated = immersive != self.immersiveApplied
            self.immersiveApplied = immersive
            // Applied in this same main-queue pass: deferring even one
            // hop lands past the frame commit, painting the new pane
            // content while the stale list pane is still on screen.
            self.applyCollapse(list: hideList, animated: animated)
        }
    }

    private func applyCollapse(list: Bool, animated: Bool) {
        guard list != listCollapsedApplied else { return }
        listCollapsedApplied = list
        guard animated else {
            listItem.isCollapsed = list
            return
        }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.32
            context.timingFunction = CAMediaTimingFunction(controlPoints: 0.4, 0, 0.2, 1)
            listItem.animator().isCollapsed = list
        }
    }
}
