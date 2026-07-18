import AppKit
import SwiftUI

/// A works listing in the reading pane — search results or a subscription's
/// associated works — with loading/error/empty overlays. Pagination (search
/// only) lives in the pane toolbar.
final class SearchResultsViewController: NSViewController, NSTableViewDataSource, NSTableViewDelegate {
    enum Context {
        case search, subscriptionWorks, authorWorks
    }

    /// What this listing shows. Derived from observable model state inside
    /// render() so a section change re-renders — a stored var assigned from
    /// outside would neither trigger nor be seen by observation tracking,
    /// leaving the pane showing the previous context's (possibly empty) list.
    private var context: Context {
        switch model.section {
        case .authors, .authorWorks: return .authorWorks
        case .subscriptions: return .subscriptionWorks
        default: return .search
        }
    }

    private let theme: AppTheme
    private let appState: AppState
    private let model: MacAppModel

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
        }

        overlayHost?.removeFromSuperview()
        overlayHost = nil
        let overlay: AnyView?
        switch context {
        case .search:
            if !model.search.hasSearched {
                overlay = AnyView(EmptyStateMac(theme: theme, icon: "magnifyingglass",
                                                title: "Search the archive",
                                                message: "Set your criteria in the middle pane and press Search."))
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

        let ids = works.map(\.id)
        if ids != renderedWorkIDs {
            tableView.reloadData()
            tableView.scroll(.zero)
        } else {
            tableView.enumerateAvailableRowViews { [weak self] _, row in
                guard let self, row < works.count,
                      let cell = tableView.view(atColumn: 0, row: row, makeIfNecessary: false) as? WorkRowCellView
                else { return }
                cell.setSelected(works[row].id == model.selectedWorkID)
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
                       summaryExpanded: true,
                       tagsExpanded: expandedTags.contains(work.id),
                       availableTextWidth: max(100, tableWidth - 45))
        cell.onToggleTags = { [weak self] in
            self?.toggleTags(workID: work.id)
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

    func tableView(_ tableView: NSTableView, shouldShowCellExpansionFor tableColumn: NSTableColumn?, row: Int) -> Bool {
        false
    }
}

// MARK: - Row context menu

extension SearchResultsViewController: NSMenuDelegate {
    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let row = tableView.clickedRow
        guard row >= 0, row < works.count else { return }
        let work = works[row]
        let started = (appState.progressMap[work.id]?.chapter ?? 0) > 0

        menu.addItem(menuItem("Open", #selector(menuOpenWork(_:)), row))
        menu.addItem(menuItem(started ? "Continue Reading" : "Start Reading",
                              #selector(menuReadWork(_:)), row))
        menu.addItem(.separator())
        menu.addItem(menuItem(appState.bookmarkedWorkIDs.contains(work.id) ? "Remove Bookmark" : "Bookmark",
                              #selector(menuToggleBookmark(_:)), row))
        if appState.bookmarkedWorkIDs.contains(work.id) {
            menu.addItem(menuItem("Edit Bookmark…", #selector(menuEditBookmark(_:)), row))
        }
        menu.addItem(menuItem(appState.downloadedWorkIDs.contains(work.id) ? "Delete Download" : "Download for Offline",
                              #selector(menuToggleDownload(_:)), row))
        if UInt64(work.id) != nil {
            menu.addItem(menuItem("Copy AO3 Link", #selector(menuCopyWorkLink(_:)), row))
        }
    }

    private func menuItem(_ title: String, _ action: Selector, _ row: Int) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        item.tag = row
        return item
    }

    private func clickedWork(_ sender: NSMenuItem) -> Work? {
        sender.tag >= 0 && sender.tag < works.count ? works[sender.tag] : nil
    }

    @objc private func menuOpenWork(_ sender: NSMenuItem) {
        guard let work = clickedWork(sender) else { return }
        model.selectWork(work.id)
    }

    @objc private func menuReadWork(_ sender: NSMenuItem) {
        guard let work = clickedWork(sender) else { return }
        let chapter = max(0, (appState.progressMap[work.id]?.chapter ?? 1) - 1)
        model.openReader(work.id, chapter: chapter)
    }

    @objc private func menuToggleBookmark(_ sender: NSMenuItem) {
        guard let work = clickedWork(sender) else { return }
        appState.toggleBookmark(work.id)
    }

    @objc private func menuToggleDownload(_ sender: NSMenuItem) {
        guard let work = clickedWork(sender) else { return }
        appState.toggleDownload(work.id)
    }

    @objc private func menuCopyWorkLink(_ sender: NSMenuItem) {
        guard let work = clickedWork(sender), UInt64(work.id) != nil else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString("https://archiveofourown.org/works/\(work.id)", forType: .string)
    }

    @objc private func menuEditBookmark(_ sender: NSMenuItem) {
        guard let work = clickedWork(sender) else { return }
        var dismissRef: () -> Void = {}
        let view = MacBookmarkEditView(theme: theme, appState: appState,
                                       workID: work.id, workTitle: work.title,
                                       onClose: { dismissRef() })
        let hosting = NSHostingController(rootView: view)
        dismissRef = { [weak self, weak hosting] in
            if let hosting { self?.dismiss(hosting) }
        }
        presentAsSheet(hosting)
    }
}

/// Numbered pagination + prev/next for the results pane toolbar.
struct SearchPagerView: View {
    @Bindable var theme: AppTheme
    @Bindable var appState: AppState
    @Bindable var model: MacAppModel

    var body: some View {
        let _ = theme.uiFontScale  // track app text size so fonts refresh live
        let search = model.search
        let current = Int(search.currentPage)
        let lower = max(1, current - 2)
        let upper = search.hasNextPage ? current + 2 : current
        HStack(spacing: 3) {
            pagerButton(symbol: "chevron.left", enabled: current > 1) {
                search.goToPage(UInt32(current - 1), appState: appState)
            }
            ForEach(lower...max(lower, upper), id: \.self) { page in
                Button {
                    search.goToPage(UInt32(page), appState: appState)
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
                .disabled(appState.isSearching)
            }
            pagerButton(symbol: "chevron.right", enabled: search.hasNextPage) {
                search.goToPage(UInt32(current + 1), appState: appState)
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
        .disabled(!enabled || appState.isSearching)
    }
}
