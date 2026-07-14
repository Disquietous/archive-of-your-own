import AppKit
import SwiftUI

/// Middle pane: contextual list driven by the selected sidebar section.
/// Work lists render in an NSTableView backed by shared AppState data; the
/// managed-list variants (subscriptions, fandoms, authors, stats) are hosted
/// SwiftUI. Network sections surface loading / error / Tor-blocked states.
final class ListPaneViewController: NSViewController, NSTableViewDataSource, NSTableViewDelegate {
    private let theme: AppTheme
    private let appState: AppState
    private let model: MacAppModel

    private let toolbar: PaneToolbarView
    private let contentStack = NSStackView()
    private let scrollView = NSScrollView()
    private let tableView = NSTableView()

    private var chipsHost: NSHostingView<ChipsBar>?
    private var variantHost: NSView?
    private var overlayHost: NSView?
    private var eyeButton: ToolButton?
    private var refreshButton: ToolButton?
    private var loadMoreButton: ToolButton?

    private var works: [Work] = []
    private var renderedSection: MacAppModel.Section?
    private var renderedWorkIDs: [String] = []
    private var expandedSummaries: Set<String> = []
    /// Measures off-screen rows for heightOfRow.
    private lazy var sizingCell = WorkRowCellView(theme: theme)

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
        tableView.gridStyleMask = .solidHorizontalGridLineMask
        tableView.dataSource = self
        tableView.delegate = self
        tableView.backgroundColor = .clear

        scrollView.documentView = tableView
        scrollView.hasVerticalScroller = true
        scrollView.drawsBackground = false

        contentStack.orientation = .vertical
        contentStack.spacing = 0
        contentStack.distribution = .fill

        toolbar.translatesAutoresizingMaskIntoConstraints = false
        contentStack.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(toolbar)
        root.addSubview(contentStack)
        NSLayoutConstraint.activate([
            toolbar.topAnchor.constraint(equalTo: root.topAnchor),
            toolbar.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            toolbar.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            contentStack.topAnchor.constraint(equalTo: toolbar.bottomAnchor),
            contentStack.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            contentStack.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            contentStack.bottomAnchor.constraint(equalTo: root.bottomAnchor),
        ])
        view = root

        ObservationRelay.track { [weak self] in
            self?.render()
        }
    }

    // MARK: - Render

    private func render() {
        view.layer?.backgroundColor = theme.nsBg.cgColor
        tableView.gridColor = theme.nsLine
        toolbar.applyTheme()

        let section = model.section
        switch section {
        case .browse:
            works = model.works(for: .browse)
            toolbar.configure(title: "Browse", sub: subtitleForNetworkList(count: works.count, loading: appState.isBrowsing))
            toolbar.setTrailing([browseRefreshButton(), eyeToggleButton()])
            showWorksContent(section: section, chips: !model.availableTags.isEmpty,
                             overlay: networkOverlay(loading: appState.isBrowsing,
                                                     loadingMessage: "Fetching latest works…",
                                                     emptyIcon: "safari", emptyTitle: "Nothing here yet",
                                                     emptyMessage: "Connect and refresh to browse the newest works on the archive."))

        case .search:
            works = model.works(for: .search)
            let query = model.query.trimmingCharacters(in: .whitespaces)
            toolbar.configure(title: query.isEmpty ? "Search" : "“\(query)”",
                              sub: subtitleForNetworkList(count: works.count, loading: appState.isSearching))
            toolbar.setTrailing([searchLoadMoreButton(), eyeToggleButton()])
            showWorksContent(section: section, chips: !model.availableTags.isEmpty,
                             overlay: networkOverlay(loading: appState.isSearching,
                                                     loadingMessage: "Searching the archive…",
                                                     emptyIcon: "magnifyingglass", emptyTitle: "No works found",
                                                     emptyMessage: "Try a different search term, or press Return in the search field to search."))

        case .reading, .history, .bookmarks, .downloads:
            works = model.works(for: section)
            let meta = sectionMeta(for: section)
            toolbar.configure(title: meta.title, sub: "\(works.count) · \(meta.sub)")
            toolbar.setTrailing([])
            let empty = works.isEmpty
                ? AnyView(EmptyStateMac(theme: theme, icon: meta.empty.0, title: meta.empty.1, message: meta.empty.2))
                : nil
            showWorksContent(section: section, chips: false, overlay: empty)

        case .subscriptions:
            toolbar.configure(title: "Subscriptions", sub: "Followed updates")
            var buttons: [NSView] = []
            if appState.unreadNotificationCount > 0 {
                buttons.append(ToolButton(theme: theme, symbol: "checkmark", tooltip: "Mark all read") { [weak self] in
                    self?.appState.markAllNotificationsRead()
                })
            }
            buttons.append(ToolButton(theme: theme, symbol: "arrow.clockwise", tooltip: "Check now") { [weak self] in
                guard let self else { return }
                Task {
                    await self.appState.loadSubscriptions(force: true)
                    await self.appState.checkSubscriptions()
                }
            })
            toolbar.setTrailing(buttons)
            showVariant(SubscriptionsList(theme: theme, appState: appState, model: model), section: section)

        case .fandoms:
            toolbar.configure(title: "Fandoms", sub: "\(model.libraryFandoms.count) in library")
            toolbar.setTrailing([])
            showVariant(FandomsGrid(theme: theme, model: model), section: section)

        case .authors:
            toolbar.configure(title: "Authors", sub: "\(model.followedAuthors.count) followed")
            toolbar.setTrailing([])
            showVariant(AuthorsList(theme: theme, appState: appState, model: model), section: section)

        case .stats:
            toolbar.configure(title: "Reading Stats", sub: "Counted on device")
            toolbar.setTrailing([])
            showVariant(StatsView(theme: theme, model: model), section: section)
        }
        renderedSection = section
    }

    private func sectionMeta(for section: MacAppModel.Section) -> (title: String, sub: String, empty: (String, String, String)) {
        if section == .bookmarks, let listID = model.selectedReadingListID,
           let list = appState.readingLists.first(where: { $0.id == listID }) {
            return (list.name, "Reading list", ("bookmark", "Empty list", "Add works to this list from a work's details."))
        }
        switch section {
        case .reading: return ("Currently Reading", "In progress", ("book", "Nothing in progress", "Open a work to begin reading."))
        case .history: return ("History", "Recently read", ("clock", "No history yet", "Works you read appear here."))
        case .bookmarks: return ("Bookmarks", "Saved works", ("bookmark", "No bookmarks", "Bookmark works to keep them."))
        case .downloads: return ("Downloaded", "Available offline", ("arrow.down.circle", "No downloads", "Download works to read offline."))
        default: return ("Works", "", ("book", "Nothing here", ""))
        }
    }

    private func subtitleForNetworkList(count: Int, loading: Bool) -> String {
        if appState.bridge.networkBlocked { return "Tor required — not connected" }
        if loading && count == 0 { return "Loading…" }
        if let error = appState.searchError, count == 0 { return error }
        return "\(count) works"
    }

    private func networkOverlay(loading: Bool, loadingMessage: String,
                                emptyIcon: String, emptyTitle: String, emptyMessage: String) -> AnyView? {
        guard works.isEmpty else { return nil }
        if appState.bridge.networkBlocked {
            return AnyView(EmptyStateMac(theme: theme, icon: "shield.lefthalf.filled",
                                         title: "Waiting for Tor",
                                         message: "Tor is required in your settings but not connected. Connect from the sidebar's privacy pill."))
        }
        if loading {
            return AnyView(LoadingStateMac(theme: theme, message: loadingMessage,
                                           detail: "Requests are rate-limited to be kind to the archive."))
        }
        if let error = appState.searchError {
            return AnyView(EmptyStateMac(theme: theme, icon: "exclamationmark.triangle",
                                         title: "Couldn’t reach the archive", message: error))
        }
        return AnyView(EmptyStateMac(theme: theme, icon: emptyIcon, title: emptyTitle, message: emptyMessage))
    }

    // MARK: - Toolbar buttons

    private func eyeToggleButton() -> ToolButton {
        let eye = eyeButton ?? ToolButton(theme: theme, symbol: "eye", tooltip: "Hide explicit") { [weak self] in
            self?.model.hideExplicit.toggle()
        }
        eyeButton = eye
        eye.isOn = model.hideExplicit
        eye.setSymbol(model.hideExplicit ? "eye.slash" : "eye")
        return eye
    }

    private func browseRefreshButton() -> ToolButton {
        let button = refreshButton ?? ToolButton(theme: theme, symbol: "arrow.clockwise", tooltip: "Refresh") { [weak self] in
            guard let self else { return }
            Task { await self.appState.browseLatestWorks(force: true) }
        }
        refreshButton = button
        return button
    }

    private func searchLoadMoreButton() -> ToolButton {
        let button = loadMoreButton ?? ToolButton(theme: theme, symbol: "plus.rectangle.on.rectangle", tooltip: "Load more results") { [weak self] in
            guard let self else { return }
            Task { await self.appState.searchAO3More() }
        }
        loadMoreButton = button
        button.isHidden = appState.searchResults.isEmpty
        return button
    }

    // MARK: - Content swapping

    private func showWorksContent(section: MacAppModel.Section, chips: Bool, overlay: AnyView?) {
        variantHost?.removeFromSuperview()
        variantHost = nil

        if chips {
            if chipsHost == nil {
                chipsHost = NSHostingView(rootView: ChipsBar(theme: theme, model: model))
            }
            if chipsHost!.superview == nil {
                contentStack.insertArrangedSubview(chipsHost!, at: 0)
                chipsHost!.widthAnchor.constraint(equalTo: contentStack.widthAnchor).isActive = true
            }
        } else {
            chipsHost?.removeFromSuperview()
        }

        if scrollView.superview == nil {
            contentStack.addArrangedSubview(scrollView)
            scrollView.widthAnchor.constraint(equalTo: contentStack.widthAnchor).isActive = true
        }

        overlayHost?.removeFromSuperview()
        overlayHost = nil
        if let overlay {
            // Sibling of the scroll view, never inside it — NSScrollView tiles
            // its own subviews and scrambles constraint-based placement.
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
        // Phantom grid lines read as content in an empty table.
        tableView.gridStyleMask = works.isEmpty ? [] : .solidHorizontalGridLineMask

        let sectionChanged = renderedSection != section
        let ids = works.map(\.id)
        if sectionChanged || ids != renderedWorkIDs {
            tableView.reloadData()
        } else {
            // Same rows — only move the selection highlight. Reloading here
            // replaces every cell and makes expand/collapse look like a flash.
            tableView.enumerateAvailableRowViews { [weak self] _, row in
                guard let self, row < works.count,
                      let cell = tableView.view(atColumn: 0, row: row, makeIfNecessary: false) as? WorkRowCellView
                else { return }
                cell.setSelected(works[row].id == model.selectedWorkID)
            }
        }
        renderedWorkIDs = ids
        if sectionChanged {
            tableView.scroll(.zero)
        }
        // Keep the table's native selection in sync with the model (reading
        // model.selectedWorkID here also makes the relay re-render on selection
        // change, which repaints the previously selected row).
        if let selectedRow = works.firstIndex(where: { $0.id == model.selectedWorkID }) {
            if tableView.selectedRow != selectedRow {
                tableView.selectRowIndexes(IndexSet(integer: selectedRow), byExtendingSelection: false)
            }
        } else {
            tableView.deselectAll(nil)
        }
    }

    private func showVariant(_ content: some View, section: MacAppModel.Section) {
        chipsHost?.removeFromSuperview()
        scrollView.removeFromSuperview()
        overlayHost?.removeFromSuperview()
        overlayHost = nil
        // Rebuild the host when the section changes; re-render otherwise.
        if renderedSection != section || variantHost == nil {
            variantHost?.removeFromSuperview()
            let host = NSHostingView(rootView: AnyView(content))
            contentStack.addArrangedSubview(host)
            host.widthAnchor.constraint(equalTo: contentStack.widthAnchor).isActive = true
            variantHost = host
        } else if let host = variantHost as? NSHostingView<AnyView> {
            host.rootView = AnyView(content)
        }
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
        let work = works[row]
        // Row chrome: 16 leading + 3 spine + 12 gap + 40 trailing.
        let textWidth = max(100, tableView.bounds.width - 71)
        cell.configure(with: work,
                       progress: model.progress(for: work),
                       downloaded: appState.downloadedWorkIDs.contains(work.id),
                       selected: model.selectedWorkID == work.id,
                       summaryExpanded: expandedSummaries.contains(work.id),
                       availableTextWidth: textWidth)
        cell.onToggleSummary = { [weak self] in
            self?.toggleSummary(workID: work.id)
        }
        return cell
    }

    private func toggleSummary(workID: String) {
        if expandedSummaries.contains(workID) {
            expandedSummaries.remove(workID)
        } else {
            expandedSummaries.insert(workID)
        }
        guard let row = works.firstIndex(where: { $0.id == workID }) else { return }
        // Expanding a summary is also an act of focusing that work — select it
        // (fires tableViewSelectionDidChange → model.selectWork).
        tableView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        // Real in-place expand/collapse: the summary's clip-height constraint
        // and the row height animate in the same transaction, so the text
        // reveals/conceals progressively while the row grows or shrinks —
        // no reload, no cell replacement, no snapping.
        let cell = tableView.view(atColumn: 0, row: row, makeIfNecessary: false) as? WorkRowCellView
        let expanded = expandedSummaries.contains(workID)
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.22
            context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            context.allowsImplicitAnimation = true
            cell?.setSummaryExpanded(expanded)
            tableView.noteHeightOfRows(withIndexesChanged: IndexSet(integer: row))
            tableView.layoutSubtreeIfNeeded()
        }
    }

    /// Row heights come from the cells' own measurement. The automatic
    /// row-height engine was measured (see git history) applying height
    /// changes on reload only upward — a collapsed summary's shorter,
    /// correctly-measured height was silently discarded, so rows never shrank.
    func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
        guard row < works.count else { return 52 }
        // Always measure via the sizing cell — querying live row views from
        // inside heightOfRow is illegal reentrancy (AppKit throws while the
        // table is mid-tiling), and the sizing cell computes identical layout.
        let work = works[row]
        let width = max(320, tableView.bounds.width)
        sizingCell.configure(with: work,
                             progress: model.progress(for: work),
                             downloaded: appState.downloadedWorkIDs.contains(work.id),
                             selected: false,
                             summaryExpanded: expandedSummaries.contains(work.id),
                             availableTextWidth: max(100, width - 71))
        sizingCell.frame = NSRect(x: 0, y: 0, width: width, height: 10_000)
        sizingCell.layoutSubtreeIfNeeded()
        return max(52, sizingCell.fittingSize.height)
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        guard tableView.selectedRow >= 0, tableView.selectedRow < works.count else { return }
        let id = works[tableView.selectedRow].id
        // Ignore no-op changes from programmatic selection sync — selectWork
        // closes an open reader, which must only happen on a real user click.
        if model.selectedWorkID != id {
            model.selectWork(id)
        }
    }

    // The full text belongs in the expanded row, not in the hover overlay.
    func tableView(_ tableView: NSTableView, shouldShowCellExpansionFor tableColumn: NSTableColumn?, row: Int) -> Bool {
        false
    }
}
