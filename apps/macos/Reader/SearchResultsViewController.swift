import AppKit
import SwiftUI

/// A works listing in the reading pane — search results or a subscription's
/// associated works — with loading/error/empty overlays. Pagination (search
/// only) lives in the pane toolbar.
final class SearchResultsViewController: NSViewController, NSTableViewDataSource, NSTableViewDelegate {
    enum Context {
        case search, subscriptionWorks, authorWorks, fandomWorks, readingListWorks,
             collectionBookmarks
    }

    /// What this listing shows. Derived from observable model state inside
    /// render() so a section change re-renders — a stored var assigned from
    /// outside would neither trigger nor be seen by observation tracking,
    /// leaving the pane showing the previous context's (possibly empty) list.
    /// A fixedContext pins it instead, for panes that always show one thing
    /// (the split collection view's works and bookmarks halves).
    private var context: Context {
        if let fixedContext { return fixedContext }
        switch model.section {
        case .authors, .authorWorks: return .authorWorks
        case .subscriptions: return .subscriptionWorks
        case .fandoms: return model.fandomSearchActive ? .search : .fandomWorks
        case .readingLists: return .readingListWorks
        default: return .search
        }
    }

    private let theme: AppTheme
    private let appState: AppState
    private let model: MacAppModel
    private let fixedContext: Context?

    private let scrollView = NSScrollView()
    private let tableView = KeyNavTableView()
    private var overlayHost: NSView?
    private var works: [Work] = []
    private var renderedWorkIDs: [String] = []
    private var expandedTags: Set<String> = []
    private var renderedDensity: Density?
    private var renderedUIScale: Double?
    /// Width the rows were last measured at — see ListPaneViewController.
    private var lastLayoutWidth: CGFloat = 0
    private lazy var sizingCell = WorkRowCellView(theme: theme)
    /// Shared work-row context menu (same items as the list pane).
    private lazy var workRowMenu = WorkRowMenuController(
        theme: theme, appState: appState, model: model, presenter: self
    ) { [weak self] row in
        guard let self, row >= 0, row < self.works.count else { return nil }
        return self.works[row]
    }

    init(theme: AppTheme, appState: AppState, model: MacAppModel,
         fixedContext: Context? = nil) {
        self.theme = theme
        self.appState = appState
        self.model = model
        self.fixedContext = fixedContext
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override func loadView() {
        let root = NSView()
        root.wantsLayer = true

        let column = NSTableColumn(identifier: .init("result"))
        column.resizingMask = .autoresizingMask
        tableView.addTableColumn(column)
        tableView.headerView = nil
        tableView.style = .plain
        tableView.selectionHighlightStyle = .none
        tableView.intercellSpacing = .zero
        tableView.dataSource = self
        tableView.delegate = self
        tableView.backgroundColor = .clear
        // Click action, not just selectionDidChange: re-clicking the row the
        // table still has selected (after backing out of the detail view)
        // fires no selection change, but must still navigate.
        tableView.target = self
        tableView.action = #selector(rowClicked)
        // Return opens the reader for the selected work at its saved position.
        tableView.onReturn = { [weak self] in
            guard let self, let id = model.selectedWorkID else { return }
            let chapter = max(0, (appState.progressMap[id]?.chapter ?? 1) - 1)
            model.openReader(id, chapter: chapter)
        }
        // Right-click menu — mirrors the list pane's row actions.
        let rowMenu = NSMenu()
        rowMenu.delegate = self
        tableView.menu = rowMenu

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
            renderedWorkIDs = []
        }
        switch context {
        case .search: works = model.works(for: .search)
        case .subscriptionWorks: works = model.filteredSubscriptionWorks
        case .authorWorks: works = model.filteredAuthorWorks
        case .fandomWorks: works = model.fandomLibraryWorks
        case .readingListWorks: works = model.filteredReadingListWorks
        case .collectionBookmarks: works = model.search.bookmarkResults
        }

        overlayHost?.removeFromSuperview()
        overlayHost = nil
        let overlay: AnyView?
        switch context {
        case .search:
            if !model.search.hasSearched {
                overlay = AnyView(EmptyStateMac(theme: theme, icon: "magnifyingglass",
                                                title: "Search the archive",
                                                message: "Set your criteria and press Search."))
            } else if appState.isSearching && works.isEmpty {
                overlay = AnyView(LoadingStateMac(theme: theme, message: "Searching the archive…",
                                                  detail: "Requests are rate-limited to be kind to the archive.",
                                                  otherActivity: otherActivity(excluding: "Searching the archive")))
            } else if let error = appState.searchError, works.isEmpty {
                overlay = AnyView(EmptyStateMac(theme: theme, icon: "exclamationmark.triangle",
                                                title: "Couldn’t reach the archive", message: error))
            } else if works.isEmpty {
                overlay = AnyView(EmptyStateMac(theme: theme, icon: "magnifyingglass",
                                                title: "No works found",
                                                message: model.search.currentPage > 1
                                                    ? "No results on page \(model.search.currentPage) — try an earlier page."
                                                    : "Try different terms or fewer filters."))
            } else {
                overlay = nil
            }
        case .subscriptionWorks:
            let who = model.subscriptionWorksTitle ?? "this author"
            if model.isLoadingSubscriptionWorks && works.isEmpty {
                overlay = AnyView(LoadingStateMac(theme: theme,
                                                  message: model.subscriptionWorksFetchStatus ?? "Fetching works by \(who)…",
                                                  detail: "Fetching every page of \(who)’s works. Requests are rate-limited to be kind to the archive.",
                                                  otherActivity: otherActivity(excluding: "Fetching \(who)")))
            } else if let error = model.subscriptionWorksError, works.isEmpty {
                overlay = AnyView(EmptyStateMac(theme: theme, icon: "exclamationmark.triangle",
                                                title: "Couldn’t load works", message: error))
            } else if works.isEmpty {
                overlay = AnyView(EmptyStateMac(theme: theme, icon: "person",
                                                title: "No works stored",
                                                message: "Press Refresh Works to fetch \(who)’s complete works list from AO3."))
            } else {
                overlay = nil
            }
        case .authorWorks:
            let who = model.authorUsername ?? "this author"
            if model.isLoadingAuthor && works.isEmpty {
                overlay = AnyView(LoadingStateMac(theme: theme,
                                                  message: model.authorFetchStatus ?? "Fetching works by \(who)…",
                                                  detail: "Fetching every page of \(who)’s works. Requests are rate-limited to be kind to the archive.",
                                                  otherActivity: otherActivity(excluding: "Fetching \(who)")))
            } else if let error = model.authorError, works.isEmpty {
                overlay = AnyView(EmptyStateMac(theme: theme, icon: "exclamationmark.triangle",
                                                title: "Couldn’t load works", message: error))
            } else if works.isEmpty {
                overlay = AnyView(EmptyStateMac(theme: theme, icon: "person",
                                                title: "No works stored",
                                                message: "Press Refresh Works to fetch \(who)’s complete works list from AO3."))
            } else {
                overlay = nil
            }
        case .fandomWorks:
            if works.isEmpty {
                let tag = model.fandomWorksTag ?? "this fandom"
                overlay = AnyView(EmptyStateMac(theme: theme, icon: "flame",
                                                title: "Nothing in your library yet",
                                                message: "Works from \(tag) you’ve opened or downloaded appear here. Press Search AO3 above to find works on the archive."))
            } else {
                overlay = nil
            }
        case .readingListWorks:
            if works.isEmpty {
                overlay = AnyView(EmptyStateMac(theme: theme, icon: "books.vertical",
                                                title: "Empty list",
                                                message: "Right-click any work and choose Add to Reading List."))
            } else {
                overlay = nil
            }
        case .collectionBookmarks:
            if model.search.isFetchingBookmarks && works.isEmpty {
                overlay = AnyView(LoadingStateMac(theme: theme, message: "Fetching bookmarked items…",
                                                  detail: "Requests are rate-limited to be kind to the archive.",
                                                  otherActivity: otherActivity(excluding: "Fetching bookmarked items")))
            } else if let error = model.search.bookmarksError, works.isEmpty {
                overlay = AnyView(EmptyStateMac(theme: theme, icon: "exclamationmark.triangle",
                                                title: "Couldn’t reach the archive", message: error))
            } else if works.isEmpty {
                overlay = AnyView(EmptyStateMac(theme: theme, icon: "bookmark",
                                                title: "No bookmarked works",
                                                message: "This collection’s bookmarked items include no works the app can show."))
            } else {
                overlay = nil
            }
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

        // Content-aware signature — data refreshes must repaint rows even
        // when the id set is unchanged (see ListPaneViewController).
        let ids = works.map { "\($0.id)|\($0.updated)|\($0.chapterCount)|\($0.words)" }
        if ids != renderedWorkIDs {
            tableView.reloadData()
            tableView.scroll(.zero)
        } else {
            // Same rows — only move the selection highlight and bookmark
            // indicator, as in ListPaneViewController. (Reading
            // bookmarkedWorkIDs also re-renders the moment a bookmark
            // toggles.)
            let bookmarked = appState.bookmarkedWorkIDs
            tableView.enumerateAvailableRowViews { [weak self] _, row in
                guard let self, row < works.count,
                      let cell = tableView.view(atColumn: 0, row: row, makeIfNecessary: false) as? WorkRowCellView
                else { return }
                cell.setSelected(works[row].id == model.selectedWorkID)
                cell.setBookmarked(bookmarked.contains(works[row].id))
            }
        }
        renderedWorkIDs = ids
    }

    /// In-flight operations other than the one named, for the loading summary.
    private func otherActivity(excluding prefix: String) -> [String] {
        model.inFlightOperations.filter { !$0.hasPrefix(prefix) }
    }

    // MARK: - Table

    func numberOfRows(in tableView: NSTableView) -> Int {
        works.count
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let cell: WorkRowCellView
        if let reused = tableView.makeView(withIdentifier: WorkRowCellView.reuseID, owner: self) as? WorkRowCellView {
            cell = reused
        } else {
            cell = WorkRowCellView(theme: theme)
            cell.identifier = WorkRowCellView.reuseID
        }
        configureCell(cell, with: works[row], tableWidth: tableView.bounds.width)
        return cell
    }

    private func configureCell(_ cell: WorkRowCellView, with work: Work, tableWidth: CGFloat) {
        cell.configure(with: work,
                       progress: model.progress(for: work),
                       downloaded: appState.downloadedWorkIDs.contains(work.id),
                       selected: model.selectedWorkID == work.id,
                       bookmarked: appState.bookmarkedWorkIDs.contains(work.id),
                       summaryExpanded: true,
                       tagsExpanded: expandedTags.contains(work.id),
                       availableTextWidth: max(100, tableWidth - 45))
        cell.onToggleTags = { [weak self] in
            self?.toggleTags(workID: work.id)
        }
        cell.onToggleBookmark = { [weak self] in
            self?.appState.toggleBookmark(work.id)
        }
    }

    private func toggleTags(workID: String) {
        if expandedTags.contains(workID) {
            expandedTags.remove(workID)
        } else {
            expandedTags.insert(workID)
        }
        guard let row = works.firstIndex(where: { $0.id == workID }) else { return }
        let cell = tableView.view(atColumn: 0, row: row, makeIfNecessary: false) as? WorkRowCellView
        let expanded = expandedTags.contains(workID)
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.22
            context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            context.allowsImplicitAnimation = true
            cell?.setTagsExpanded(expanded)
            tableView.noteHeightOfRows(withIndexesChanged: IndexSet(integer: row))
            tableView.layoutSubtreeIfNeeded()
        }
    }

    func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
        guard row < works.count else { return 52 }
        let width = max(320, tableView.bounds.width)
        configureCell(sizingCell, with: works[row], tableWidth: width)
        sizingCell.frame = NSRect(x: 0, y: 0, width: width, height: 10_000)
        sizingCell.layoutSubtreeIfNeeded()
        return max(52, sizingCell.fittingSize.height)
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        guard tableView.selectedRow >= 0, tableView.selectedRow < works.count else { return }
        let id = works[tableView.selectedRow].id
        if model.selectedWorkID != id {
            model.selectWork(id)
        }
    }

    @objc private func rowClicked() {
        let row = tableView.clickedRow
        guard row >= 0, row < works.count else { return }
        let id = works[row].id
        // selectionDidChange already handled a changed selection; this covers
        // the stale-selection re-click and reopening the detail over a reader.
        if model.selectedWorkID != id || model.readerOpen {
            model.selectWork(id)
        }
    }

    func tableView(_ tableView: NSTableView, shouldShowCellExpansionFor tableColumn: NSTableColumn?, row: Int) -> Bool {
        false
    }

    // Swipe right → Remove, inside a reading list only (matching the other
    // removable lists).
    func tableView(_ tableView: NSTableView, rowActionsForRow row: Int,
                   edge: NSTableView.RowActionEdge) -> [NSTableViewRowAction] {
        guard edge == .leading, context == .readingListWorks,
              row < works.count, let listID = model.selectedReadingListID else { return [] }
        let workID = works[row].id
        let remove = NSTableViewRowAction(style: .destructive, title: "Remove") { [weak self] _, _ in
            self?.appState.removeFromReadingList(listID, workId: workID)
            tableView.rowActionsVisible = false
        }
        return [remove]
    }
}

// MARK: - Row context menu

extension SearchResultsViewController: NSMenuDelegate {
    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let row = tableView.clickedRow
        guard row >= 0, row < works.count else { return }
        let work = works[row]

        workRowMenu.addStandardItems(to: menu, for: work, row: row)
        if context == .readingListWorks,
           let listID = model.selectedReadingListID,
           let list = appState.readingLists.first(where: { $0.id == listID }) {
            menu.addItem(.separator())
            menu.addItem(workRowMenu.workItem("Remove from \u{201C}\(list.name)\u{201D}", row: row) { [weak self] work in
                self?.appState.removeFromReadingList(listID, workId: work.id)
            })
        }
    }
}

/// Numbered pagination + prev/next for the works results state in the pane
/// toolbar — a PagerControl bound to the shared search paging.
struct SearchPagerView: View {
    @Bindable var theme: AppTheme
    @Bindable var appState: AppState
    @Bindable var model: MacAppModel

    var body: some View {
        let search = model.search
        PagerControl(theme: theme,
                     current: Int(search.currentPage),
                     total: Int(search.totalPages),
                     hasNext: search.hasNextPage,
                     busy: appState.isSearching) { page in
            search.goToPage(page, appState: appState)
        }
    }
}

/// The split collection view's bookmarks-pane pager — independent of the
/// works pane's paging.
struct CollectionBookmarksPagerView: View {
    @Bindable var theme: AppTheme
    @Bindable var appState: AppState
    @Bindable var model: MacAppModel

    var body: some View {
        let search = model.search
        PagerControl(theme: theme,
                     current: Int(search.bookmarksPage),
                     total: Int(search.bookmarksTotalPages),
                     hasNext: search.bookmarksHasNext,
                     busy: search.isFetchingBookmarks) { page in
            search.goToBookmarksPage(page, appState: appState)
        }
    }
}

/// Numbered pagination + prev/next, with a jump-to-page field when the
/// listing spans more pages than the ±2 window. State comes from the
/// caller, so any independently paged listing can host one.
struct PagerControl: View {
    @Bindable var theme: AppTheme
    let current: Int
    let total: Int
    let hasNext: Bool
    let busy: Bool
    let onGo: (UInt32) -> Void

    @State private var jumpText = ""

    var body: some View {
        let _ = theme.uiFontScale  // track app text size so fonts refresh live
        let lower = max(1, current - 2)
        let upper = hasNext ? min(current + 2, max(total, current + 2)) : current
        HStack(spacing: 3) {
            pagerButton(symbol: "chevron.left", enabled: current > 1) {
                onGo(UInt32(current - 1))
            }
            ForEach(lower...max(lower, upper), id: \.self) { page in
                Button {
                    onGo(UInt32(page))
                } label: {
                    Text("\(page)")
                        .font(Font(MacFont.ui(12, weight: page == current ? .bold : .semibold)))
                        .foregroundStyle(page == current ? theme.onAccent : theme.ink2)
                        .frame(minWidth: 24, minHeight: 24)
                        .background(page == current ? theme.accent : .clear)
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(busy)
            }
            pagerButton(symbol: "chevron.right", enabled: hasNext) {
                onGo(UInt32(current + 1))
            }
            // Jump-to-page, once the real total says the window can't reach
            // everything: "· ⟨field⟩ of 42".
            if total > upper {
                Text("·")
                    .font(Font(MacFont.ui(12)))
                    .foregroundStyle(theme.ink3)
                TextField("\(current)", text: $jumpText)
                    .textFieldStyle(.plain)
                    .multilineTextAlignment(.center)
                    .font(Font(MacFont.ui(12, weight: .semibold)))
                    .foregroundStyle(theme.ink)
                    .frame(width: 38, height: 22)
                    .background(theme.surface2)
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                    .onSubmit {
                        if let page = Int(jumpText.trimmingCharacters(in: .whitespaces)),
                           page >= 1 {
                            onGo(UInt32(min(page, total)))
                        }
                        jumpText = ""
                    }
                    .disabled(busy)
                    .help("Jump to page")
                Text("of \(total)")
                    .font(Font(MacFont.ui(12)))
                    .foregroundStyle(theme.ink3)
            }
        }
    }

    private func pagerButton(symbol: String, enabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(enabled ? theme.ink2 : theme.ink3.opacity(0.4))
                .frame(width: 24, height: 24)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!enabled || busy)
    }
}
