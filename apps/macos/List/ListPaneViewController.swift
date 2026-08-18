import AppKit
import SwiftUI

/// Middle pane: contextual list driven by the selected sidebar section.
/// Work lists render in an NSTableView backed by shared AppState data; the
/// managed-list variants (subscriptions, fandoms, authors, stats) are hosted
/// SwiftUI. Network sections surface loading / error / Tor-blocked states.
final class ListPaneViewController: NSViewController, NSTableViewDataSource, NSTableViewDelegate {
    let theme: AppTheme
    let appState: AppState
    let model: MacAppModel

    let toolbar: PaneToolbarView
    let contentStack = NSStackView()
    let scrollView = NSScrollView()
    let tableView = KeyNavTableView()

    var chipsHost: NSView?
    var filterPopover: NSPopover?
    var variantHost: NSView?
    var overlayHost: NSView?
    var eyeButton: ToolButton?
    var loadMoreButton: ToolButton?
    var searchButton: ToolButton?
    var removeAllButton: ToolButton?
    var clearHistoryBtn: ToolButton?
    /// Author view: the drilled-in author's profile card, hosted in this
    /// pane while the reading pane shows their lists.
    var authorProfileController: AuthorProfileViewController?
    var authorBackBtn: ToolButton?
    var authorFollowBtn: ToolButton?
    var authorProfileRefreshBtn: ToolButton?
    var authorAO3Btn: LabelToolButton?
    /// Memoized per key: render() rebuilds the toolbar constantly, and a
    /// recreated button would yank the popover's anchor out of the view
    /// hierarchy — dismissing the dialog the moment it opens (or on the
    /// first keystroke, which re-renders via the filter state).
    var filterButtons: [String: ToolButton] = [:]

    var statusBar: NSView!
    var statusLabel: NSTextField!
    var statusSpinner: NSProgressIndicator!
    var statusBarHeight: NSLayoutConstraint!

    var inboxPrevButton: ToolButton?
    var inboxNextButton: ToolButton?
    var inboxPageField: NSTextField?
    var inboxPageContainer: NSView?

    var works: [Work] = []
    var displayedSubscriptions: [USubscription] = []
    /// Per-row "Checked …" stamps keyed "subType:subId" — captured during
    /// render (an observable read, so stamp changes re-render the list).
    var displayedLastChecked: [String: String] = [:]
    var renderedSection: MacAppModel.Section?
    var renderedWorkIDs: [String] = []
    var renderedSubscriptionIDs: [String] = []
    var expandedSummaries: Set<String> = []
    var expandedTags: Set<String> = []
    var renderedDensity: Density?
    var renderedUIScale: Double?
    /// Width the rows were last measured at. Row heights depend on wrap width,
    /// and the first render happens before layout gives the table its real
    /// width — rows measured at the fallback width keep excess bottom space.
    private var lastLayoutWidth: CGFloat = 0
    var isShowingSubscriptionList: Bool {
        model.section == .subscriptions
    }
    var isShowingReadingLists: Bool {
        model.section == .readingLists
    }
    var displayedReadingLists: [UReadingList] = []
    var renderedReadingListIDs: [Int64] = []
    /// Measures off-screen rows for heightOfRow.
    lazy var sizingCell = WorkRowCellView(theme: theme)
    lazy var subscriptionSizingCell = SubscriptionRowCellView(theme: theme)
    lazy var readingListSizingCell = ReadingListRowCellView(theme: theme)
    lazy var sortFilterMenu = SortFilterMenuController(theme: theme, model: model)
    /// Shared work-row context menu (same items as search results).
    lazy var workRowMenu = WorkRowMenuController(
        theme: theme, appState: appState, model: model, presenter: self
    ) { [weak self] row in
        guard let self, row >= 0, row < self.works.count else { return nil }
        return self.works[row]
    }

    init(theme: AppTheme, appState: AppState, model: MacAppModel) {
        self.theme = theme
        self.appState = appState
        self.model = model
        self.toolbar = PaneToolbarView(theme: theme)
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override func loadView() {
        let root = NSView()
        root.wantsLayer = true

        let column = NSTableColumn(identifier: .init("work"))
        column.resizingMask = .autoresizingMask
        tableView.addTableColumn(column)
        tableView.headerView = nil
        tableView.style = .plain
        tableView.selectionHighlightStyle = .none
        tableView.intercellSpacing = .zero
        // No table grid: NSTableView paints phantom lines below the last row.
        // Each cell draws its own bottom hairline instead (as the design specs).
        tableView.dataSource = self
        tableView.delegate = self
        tableView.backgroundColor = .clear
        // Click action, not just selectionDidChange: re-clicking the row the
        // table still has selected (after the detail pane was dismissed)
        // fires no selection change, but must still navigate.
        tableView.target = self
        tableView.action = #selector(rowClicked)
        // Return opens the reader for the selected work at its saved position.
        tableView.onReturn = { [weak self] in
            guard let self, !isShowingSubscriptionList,
                  let id = model.selectedWorkID else { return }
            let chapter = max(0, (appState.progressMap[id]?.chapter ?? 1) - 1)
            model.openReader(id, chapter: chapter)
        }
        // Right-click menu — keyboard/AX-reachable equivalent of every swipe action.
        let rowMenu = NSMenu()
        rowMenu.delegate = self
        tableView.menu = rowMenu

        scrollView.documentView = tableView
        scrollView.hasVerticalScroller = true
        scrollView.drawsBackground = false

        contentStack.orientation = .vertical
        contentStack.spacing = 0
        contentStack.distribution = .fill

        let bar = NSView()
        bar.wantsLayer = true
        let spinner = NSProgressIndicator()
        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.isIndeterminate = true
        spinner.translatesAutoresizingMaskIntoConstraints = false
        let label = NSTextField(labelWithString: "")
        label.font = MacFont.ui(11.5, weight: .medium)
        label.textColor = theme.nsInk3
        label.lineBreakMode = .byTruncatingTail
        label.translatesAutoresizingMaskIntoConstraints = false
        bar.addSubview(spinner)
        bar.addSubview(label)
        let sep = NSView()
        sep.wantsLayer = true
        sep.layer?.backgroundColor = theme.nsLine.cgColor
        sep.translatesAutoresizingMaskIntoConstraints = false
        bar.addSubview(sep)
        NSLayoutConstraint.activate([
            spinner.leadingAnchor.constraint(equalTo: bar.leadingAnchor, constant: 12),
            spinner.centerYAnchor.constraint(equalTo: bar.centerYAnchor),
            label.leadingAnchor.constraint(equalTo: spinner.trailingAnchor, constant: 6),
            label.trailingAnchor.constraint(lessThanOrEqualTo: bar.trailingAnchor, constant: -12),
            label.centerYAnchor.constraint(equalTo: bar.centerYAnchor),
            sep.topAnchor.constraint(equalTo: bar.topAnchor),
            sep.leadingAnchor.constraint(equalTo: bar.leadingAnchor),
            sep.trailingAnchor.constraint(equalTo: bar.trailingAnchor),
            sep.heightAnchor.constraint(equalToConstant: 1),
        ])
        statusBar = bar
        statusLabel = label
        statusSpinner = spinner
        let barH = bar.heightAnchor.constraint(equalToConstant: 0)
        statusBarHeight = barH

        toolbar.translatesAutoresizingMaskIntoConstraints = false
        contentStack.translatesAutoresizingMaskIntoConstraints = false
        bar.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(toolbar)
        root.addSubview(contentStack)
        root.addSubview(bar)
        NSLayoutConstraint.activate([
            toolbar.topAnchor.constraint(equalTo: root.topAnchor),
            toolbar.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            toolbar.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            contentStack.topAnchor.constraint(equalTo: toolbar.bottomAnchor),
            contentStack.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            contentStack.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            contentStack.bottomAnchor.constraint(equalTo: bar.topAnchor),
            bar.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            bar.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            bar.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            barH,
        ])
        view = root

        ObservationRelay.track { [weak self] in
            self?.render()
        }
    }

    override func viewDidLayout() {
        super.viewDidLayout()
        let width = tableView.bounds.width
        guard width > 0, abs(width - lastLayoutWidth) > 0.5 else { return }
        lastLayoutWidth = width
        tableView.reloadData()
    }
}
