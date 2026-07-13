import AppKit
import SwiftUI

final class MainSplitViewController: NSSplitViewController {
    private let theme: AppTheme
    private let appState: AppState

    private let workListController: WorkListViewController
    private let readerController: ReaderViewController

    init(theme: AppTheme, appState: AppState) {
        self.theme = theme
        self.appState = appState
        self.workListController = WorkListViewController()
        self.readerController = ReaderViewController(theme: theme)
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override func viewDidLoad() {
        super.viewDidLoad()

        let sidebarController = NSHostingController(
            rootView: SidebarView(appState: appState)
        )
        let sidebarItem = NSSplitViewItem(sidebarWithViewController: sidebarController)
        sidebarItem.minimumThickness = 180
        sidebarItem.maximumThickness = 280
        addSplitViewItem(sidebarItem)

        let listItem = NSSplitViewItem(contentListWithViewController: workListController)
        listItem.minimumThickness = 260
        listItem.maximumThickness = 420
        addSplitViewItem(listItem)

        let readerItem = NSSplitViewItem(viewController: readerController)
        readerItem.minimumThickness = 400
        addSplitViewItem(readerItem)

        workListController.onSelect = { [weak self] work in
            self?.readerController.show(work: work, chapterIndex: 0)
        }
    }
}
