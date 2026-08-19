import AppKit
import SwiftUI

/// The bookmark-scope results listing in the reading pane — bookmark hits in
/// an AppKit table of BookmarkRowCellViews, with loading/empty overlays.
/// Pagination and the header filter live in the pane toolbar.
final class BookmarkResultsViewController: NSViewController, NSTableViewDataSource, NSTableViewDelegate {
    private let theme: AppTheme
    private let appState: AppState
    private let model: MacAppModel

    private let scrollView = NSScrollView()
    private let tableView = KeyNavTableView()
    private var overlayHost: NSView?
    private var hits: [UBookmarkHit] = []
    private var renderedHitIDs: [String] = []
    private var expandedWorkTags: Set<String> = []
    private var expandedBookmarkerTags: Set<String> = []
    private var renderedDensity: Density?
    private var renderedUIScale: Double?
    /// Width the rows were last measured at — see ListPaneViewController.
    private var lastLayoutWidth: CGFloat = 0
    private lazy var sizingCell = BookmarkRowCellView(theme: theme)

    init(theme: AppTheme, appState: AppState, model: MacAppModel) {
        self.theme = theme
        self.appState = appState
        self.model = model
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override func loadView() {
        let root = NSView()
        root.wantsLayer = true

        let column = NSTableColumn(identifier: .init("bookmark"))
        column.resizingMask = .autoresizingMask
        tableView.addTableColumn(column)
        tableView.headerView = nil
        tableView.style = .plain
        tableView.selectionHighlightStyle = .none
        tableView.intercellSpacing = .zero
        tableView.dataSource = self
        tableView.delegate = self
        tableView.backgroundColor = .clear
        tableView.target = self
        tableView.action = #selector(rowClicked)

        scrollView.documentView = tableView
        scrollView.hasVerticalScroller = true
        scrollView.drawsBackground = false
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(scrollView)
        NSLayoutConstraint.activate([
            scrollView.topAnchor.constraint(equalTo: root.topAnchor),
            scrollView.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: root.bottomAnchor),
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

    private func render() {
        view.layer?.backgroundColor = theme.nsBg.cgColor
        // Density and app text size change row metrics — force a reload so
        // rows re-measure.
        if renderedDensity != theme.density || renderedUIScale != theme.uiFontScale {
            renderedDensity = theme.density
            renderedUIScale = theme.uiFontScale
            renderedHitIDs = []
        }
        let search = model.search
        hits = search.filteredBookmarkHits

        overlayHost?.removeFromSuperview()
        overlayHost = nil
        let overlay: AnyView?
        if appState.isSearching && hits.isEmpty {
            overlay = AnyView(LoadingStateMac(theme: theme, message: "Searching…",
                                              detail: "Requests are rate-limited to be kind to the archive.",
                                              otherActivity: []))
        } else if hits.isEmpty {
            if search.bookmarkListFilter.isActive && !search.bookmarkHits.isEmpty {
                overlay = AnyView(EmptyStateMac(
                    theme: theme, icon: "line.3.horizontal.decrease.circle",
                    title: "No bookmarks match the filter",
                    message: "Adjust or clear the header filter to see the results again."))
            } else {
                overlay = AnyView(EmptyStateMac(
                    theme: theme, icon: "magnifyingglass",
                    title: search.searchLibraryOnly ? "No matches in your library" : "No matches on AO3",
                    message: search.searchLibraryOnly
                        ? "Only what the app has already cached is searched. Browse or fetch more to grow the library."
                        : "Nothing on AO3 matched these criteria."))
            }
        } else {
            overlay = nil
        }
        if let overlay {
            let host = NSHostingView(rootView: overlay)
            host.translatesAutoresizingMaskIntoConstraints = false
            view.addSubview(host)
            NSLayoutConstraint.activate([
                host.centerXAnchor.constraint(equalTo: scrollView.centerXAnchor),
                host.centerYAnchor.constraint(equalTo: scrollView.centerYAnchor),
                host.widthAnchor.constraint(lessThanOrEqualTo: scrollView.widthAnchor),
            ])
            overlayHost = host
        }

        // Follow-bell inputs, read on every render path so the relay
        // re-renders the moment a follow or AO3 subscription toggles
        // (see ListPaneViewController.showWorksContent).
        _ = model.followedAuthorNames
        _ = appState.subscriptions

        // Content-aware signature — data refreshes must repaint rows even
        // when the hit set looks similar (see ListPaneViewController).
        let ids = hits.map(Self.hitKey)
        if ids != renderedHitIDs {
            expandedWorkTags = []
            expandedBookmarkerTags = []
            tableView.reloadData()
            tableView.scroll(.zero)
        } else {
            // Same rows — re-shade the visible byline bells in place.
            tableView.enumerateAvailableRowViews { [weak self] _, row in
                guard let self,
                      let cell = tableView.view(atColumn: 0, row: row, makeIfNecessary: false) as? BookmarkRowCellView
                else { return }
                cell.updateFollowBells { self.model.authorFollowState($0) }
            }
        }
        renderedHitIDs = ids
    }

    /// Stable row key: the same work can be bookmarked by several users in
    /// one result set, so the work id alone is not unique.
    private static func hitKey(_ hit: UBookmarkHit) -> String {
        "\(hit.bookmarker)|\(hit.work.id)|\(hit.dateBookmarked)"
    }

    // MARK: - Table

    func numberOfRows(in tableView: NSTableView) -> Int {
        hits.count
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let cell: BookmarkRowCellView
        if let reused = tableView.makeView(withIdentifier: BookmarkRowCellView.reuseID, owner: self) as? BookmarkRowCellView {
            cell = reused
        } else {
            cell = BookmarkRowCellView(theme: theme)
            cell.identifier = BookmarkRowCellView.reuseID
        }
        configureCell(cell, with: hits[row], tableWidth: tableView.bounds.width)
        return cell
    }

    private func configureCell(_ cell: BookmarkRowCellView, with hit: UBookmarkHit, tableWidth: CGFloat) {
        let key = Self.hitKey(hit)
        cell.configure(with: hit,
                       workTagsExpanded: expandedWorkTags.contains(key),
                       bookmarkerTagsExpanded: expandedBookmarkerTags.contains(key),
                       availableTextWidth: max(100, tableWidth - 45),
                       followState: { [weak self] in
                           self?.model.authorFollowState($0) ?? .none
                       })
        cell.onToggleWorkTags = { [weak self] in
            self?.toggleTags(key: key, in: \.expandedWorkTags)
        }
        cell.onToggleBookmarkerTags = { [weak self] in
            self?.toggleTags(key: key, in: \.expandedBookmarkerTags)
        }
        cell.onAuthorClick = { [weak self] author in
            self?.model.openAuthorProfile(author)
        }
        cell.onToggleFollow = { [weak self] author in
            self?.model.toggleAuthorFollow(author)
        }
    }

    private func toggleTags(key: String, in set: ReferenceWritableKeyPath<BookmarkResultsViewController, Set<String>>) {
        if self[keyPath: set].contains(key) {
            self[keyPath: set].remove(key)
        } else {
            self[keyPath: set].insert(key)
        }
        guard let row = hits.firstIndex(where: { Self.hitKey($0) == key }) else { return }
        let cell = tableView.view(atColumn: 0, row: row, makeIfNecessary: false) as? BookmarkRowCellView
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.22
            context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            context.allowsImplicitAnimation = true
            cell?.setWorkTagsExpanded(expandedWorkTags.contains(key))
            cell?.setBookmarkerTagsExpanded(expandedBookmarkerTags.contains(key))
            tableView.noteHeightOfRows(withIndexesChanged: IndexSet(integer: row))
            tableView.layoutSubtreeIfNeeded()
        }
    }

    func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
        guard row < hits.count else { return 52 }
        let width = max(320, tableView.bounds.width)
        configureCell(sizingCell, with: hits[row], tableWidth: width)
        sizingCell.frame = NSRect(x: 0, y: 0, width: width, height: 10_000)
        sizingCell.layoutSubtreeIfNeeded()
        return max(52, sizingCell.fittingSize.height)
    }

    @objc private func rowClicked() {
        let row = tableView.clickedRow
        guard row >= 0, row < hits.count else { return }
        model.openWorkByID(String(hits[row].work.id))
    }

    func tableView(_ tableView: NSTableView, shouldShowCellExpansionFor tableColumn: NSTableColumn?, row: Int) -> Bool {
        false
    }
}
