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
    private var authorBackButton: ToolButton?
    private var authorMoreButton: ToolButton?

    private var works: [Work] = []
    private var displayedSubscriptions: [USubscription] = []
    private var renderedSection: MacAppModel.Section?
    private var renderedWorkIDs: [String] = []
    private var renderedSubscriptionIDs: [String] = []
    private var expandedSummaries: Set<String> = []
    private var isShowingSubscriptionList: Bool {
        model.section == .subscriptions && model.subscriptionSubTab == "following"
    }
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
        // No table grid: NSTableView paints phantom lines below the last row.
        // Each cell draws its own bottom hairline instead (as the design specs).
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
        toolbar.applyTheme()

        let section = model.section
        switch section {
        case .browse:
            works = model.works(for: .browse)
            toolbar.configure(title: "Browse", sub: subtitleForNetworkList(count: works.count, loading: appState.isBrowsing))
            toolbar.setLeading([])
            toolbar.setTrailing([browseRefreshButton(), eyeToggleButton()])
            showWorksContent(section: section, header: chipsHeader(),
                             overlay: networkOverlay(loading: appState.isBrowsing,
                                                     loadingMessage: "Fetching latest works…",
                                                     emptyIcon: "safari", emptyTitle: "Nothing here yet",
                                                     emptyMessage: "Connect and refresh to browse the newest works on the archive."))

        case .search:
            toolbar.configure(title: "Search", sub: model.search.formFields.isEmpty ? "Criteria" : "AO3 criteria")
            toolbar.setLeading([])
            toolbar.setTrailing([searchGoButton(), reloadFieldsButton(), eyeToggleButton()])
            showVariant(SearchFormView(theme: theme, appState: appState, model: model), section: section)

        case .authorWorks:
            works = model.works(for: .authorWorks)
            toolbar.configure(title: model.authorUsername ?? "Author",
                              sub: model.isLoadingAuthor && works.isEmpty ? "Loading…" : "\(works.count) works")
            toolbar.setLeading([authorBack()])
            toolbar.setTrailing([authorLoadMore()])
            let authorOverlay: AnyView?
            if works.isEmpty {
                if model.isLoadingAuthor {
                    authorOverlay = AnyView(LoadingStateMac(theme: theme, message: "Fetching works by \(model.authorUsername ?? "author")…"))
                } else if let error = model.authorError {
                    authorOverlay = AnyView(EmptyStateMac(theme: theme, icon: "exclamationmark.triangle",
                                                          title: "Couldn’t load author", message: error))
                } else {
                    authorOverlay = AnyView(EmptyStateMac(theme: theme, icon: "person",
                                                          title: "No works", message: "This author has no visible works."))
                }
            } else {
                authorOverlay = nil
            }
            showWorksContent(section: section, header: nil, overlay: authorOverlay)

        case .reading, .history, .bookmarks, .downloads:
            works = model.works(for: section)
            let meta = sectionMeta(for: section)
            toolbar.configure(title: meta.title, sub: "\(works.count) · \(meta.sub)")
            toolbar.setLeading([])
            toolbar.setTrailing(section == .reading && !works.isEmpty ? [removeAllReadingButton()] : [])
            let empty = works.isEmpty
                ? AnyView(EmptyStateMac(theme: theme, icon: meta.empty.0, title: meta.empty.1, message: meta.empty.2))
                : nil
            showWorksContent(section: section, header: nil, overlay: empty)

        case .subscriptions:
            if model.subscriptionSubTab == "new" {
                works = model.works(for: .subscriptions)
                let checkStatus = appState.subscriptionCheckTask.statusMessage
                let checkSub: String
                if appState.isCheckingSubscriptions {
                    let done = appState.subscriptionCheckTotal - appState.subscriptionCheckRemaining
                    checkSub = "Checking… (\(done)/\(appState.subscriptionCheckTotal))"
                } else if let status = checkStatus, !status.isEmpty {
                    checkSub = status
                } else if works.isEmpty {
                    checkSub = "No updates"
                } else {
                    checkSub = "\(works.count) updated"
                }
                toolbar.configure(title: "What's New", sub: checkSub)
                var buttons: [NSView] = []
                if !works.isEmpty {
                    buttons.append(ToolButton(theme: theme, symbol: "trash", tooltip: "Clear all") { [weak self] in
                        self?.appState.clearNewWorks()
                    })
                }
                buttons.append(ToolButton(theme: theme, symbol: "arrow.clockwise", tooltip: "Check for updates") { [weak self] in
                    guard let self else { return }
                    Task {
                        self.appState.bridge.resetSubscriptionCheck()
                        await self.appState.checkSubscriptions()
                    }
                })
                toolbar.setLeading([subscriptionTabButtons()])
                toolbar.setTrailing(buttons)
                let overlay: AnyView?
                if appState.isCheckingSubscriptions {
                    let done = appState.subscriptionCheckTotal - appState.subscriptionCheckRemaining
                    overlay = AnyView(LoadingStateMac(theme: theme,
                        message: "Checking subscriptions…",
                        detail: "Checked \(done) of \(appState.subscriptionCheckTotal)"))
                } else if works.isEmpty {
                    overlay = AnyView(EmptyStateMac(theme: theme, icon: "bell",
                                                    title: "Nothing new",
                                                    message: checkStatus ?? "Updates from works and authors you follow appear here."))
                } else {
                    overlay = nil
                }
                showWorksContent(section: section, header: nil, overlay: overlay)
            } else {
                displayedSubscriptions = appState.subscriptions
                works = []
                let subtitle: String
                if appState.isLoadingSubscriptions {
                    subtitle = "Loading from AO3…"
                } else if let err = appState.subscriptionError, !err.isEmpty {
                    subtitle = "Error — \(err)"
                } else {
                    subtitle = "\(displayedSubscriptions.count) subscriptions"
                }
                toolbar.configure(title: "Following", sub: subtitle)
                toolbar.setLeading([subscriptionTabButtons()])
                toolbar.setTrailing([ToolButton(theme: theme, symbol: "arrow.down.circle", tooltip: "Refresh list from AO3") { [weak self] in
                    guard let self else { return }
                    guard appState.ao3Username != nil else {
                        appState.subscriptionError = "Sign in to AO3 in Settings first"
                        return
                    }
                    guard !appState.isLoadingSubscriptions else { return }
                    appState.subscriptionError = nil
                    Task { await self.appState.loadSubscriptions(force: true) }
                }])
                let overlay: AnyView?
                if appState.isLoadingSubscriptions {
                    overlay = AnyView(LoadingStateMac(theme: theme, message: "Refreshing subscriptions from AO3…",
                                                     detail: "This may take a moment over Tor.")
                        .background(theme.bg))
                } else if let err = appState.subscriptionError, !err.isEmpty {
                    overlay = AnyView(VStack(spacing: 12) {
                        Image(systemName: "exclamationmark.triangle")
                            .font(.system(size: 28, weight: .light))
                            .foregroundStyle(theme.line2)
                        Text("Couldn't load subscriptions")
                            .font(Font(MacFont.serif(18, weight: .semibold)))
                            .foregroundStyle(theme.ink2)
                        Text(err)
                            .font(Font(MacFont.ui(13)))
                            .foregroundStyle(theme.ink3)
                            .multilineTextAlignment(.center)
                            .lineLimit(nil)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(24)
                    .frame(maxWidth: .infinity)
                    .background(theme.bg))
                } else if displayedSubscriptions.isEmpty {
                    overlay = AnyView(EmptyStateMac(theme: theme, icon: "bell",
                                                   title: "No subscriptions",
                                                   message: "Works, series, and authors you subscribe to on AO3 appear here."))
                } else {
                    overlay = nil
                }
                showSubscriptionsContent(section: section, overlay: overlay)
            }

        case .fandoms:
            toolbar.configure(title: "Fandoms", sub: "\(model.followedFandoms.count) followed")
            toolbar.setLeading([])
            toolbar.setTrailing([])
            showVariant(FollowedFandomsView(theme: theme, model: model), section: section)

        case .authors:
            let count = model.followedAuthorNames.count + model.followedAuthors.count
            toolbar.configure(title: "Authors", sub: "\(count) followed")
            toolbar.setLeading([])
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

    private var searchButton: ToolButton?

    private func searchGoButton() -> ToolButton {
        let button = searchButton ?? ToolButton(theme: theme, symbol: "magnifyingglass", tooltip: "Search") { [weak self] in
            guard let self else { return }
            model.search.performSearch(appState)
        }
        searchButton = button
        button.isOn = true
        return button
    }

    private func reloadFieldsButton() -> ToolButton {
        let button = loadMoreButton ?? ToolButton(theme: theme, symbol: "arrow.clockwise", tooltip: "Reload search criteria from AO3") { [weak self] in
            guard let self else { return }
            Task { await self.model.search.scrapeForm(self.appState) }
        }
        loadMoreButton = button
        return button
    }

    private func authorBack() -> ToolButton {
        let button = authorBackButton ?? ToolButton(theme: theme, symbol: "arrow.left", tooltip: "Back to authors") { [weak self] in
            self?.model.goSection(.authors)
        }
        authorBackButton = button
        return button
    }

    private func authorLoadMore() -> ToolButton {
        let button = authorMoreButton ?? ToolButton(theme: theme, symbol: "plus.rectangle.on.rectangle", tooltip: "Load more works") { [weak self] in
            self?.model.loadMoreAuthorWorks()
        }
        authorMoreButton = button
        button.isHidden = model.authorWorksList.isEmpty
        return button
    }

    private func subscriptionTabButtons() -> NSView {
        let seg = NSSegmentedControl(labels: ["What's New", "Following"], trackingMode: .selectOne,
                                     target: self, action: #selector(subscriptionTabChanged(_:)))
        seg.selectedSegment = model.subscriptionSubTab == "new" ? 0 : 1
        seg.segmentStyle = .texturedRounded
        seg.controlSize = .small
        (seg.cell as? NSSegmentedCell)?.trackingMode = .selectOne
        return seg
    }

    @objc private func subscriptionTabChanged(_ sender: NSSegmentedControl) {
        model.subscriptionSubTab = sender.selectedSegment == 0 ? "new" : "following"
        renderedSection = nil
    }

    private var removeAllButton: ToolButton?

    private func removeAllReadingButton() -> ToolButton {
        let button = removeAllButton ?? ToolButton(theme: theme, symbol: "trash", tooltip: "Remove all") { [weak self] in
            self?.confirmRemoveAllReading()
        }
        removeAllButton = button
        return button
    }

    private func confirmRemoveAllReading() {
        guard let window = view.window else { return }
        let alert = NSAlert()
        alert.messageText = "Remove All from Currently Reading?"
        alert.informativeText = "This clears the saved reading position for every work in the list. The works stay in your history, bookmarks, and downloads."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Remove All")
        alert.addButton(withTitle: "Cancel")
        alert.buttons.first?.hasDestructiveAction = true
        alert.beginSheetModal(for: window) { [weak self] response in
            guard let self, response == .alertFirstButtonReturn else { return }
            model.removeAllCurrentlyReading()
        }
    }

    private func chipsHeader() -> NSView? {
        guard !model.availableTags.isEmpty else { return nil }
        if chipsHost == nil {
            chipsHost = NSHostingView(rootView: ChipsBar(theme: theme, model: model))
        }
        return chipsHost
    }


    // MARK: - Content swapping

    private func showWorksContent(section: MacAppModel.Section, header: NSView?, overlay: AnyView?) {
        variantHost?.removeFromSuperview()
        variantHost = nil

        // Swap the pane header (tag chips for browse).
        if chipsHost !== header {
            chipsHost?.removeFromSuperview()
        }
        if let header, header.superview == nil {
            contentStack.insertArrangedSubview(header, at: 0)
            header.widthAnchor.constraint(equalTo: contentStack.widthAnchor).isActive = true
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

    private func showSubscriptionsContent(section: MacAppModel.Section, overlay: AnyView?) {
        variantHost?.removeFromSuperview()
        variantHost = nil
        chipsHost?.removeFromSuperview()

        if scrollView.superview == nil {
            contentStack.addArrangedSubview(scrollView)
            scrollView.widthAnchor.constraint(equalTo: contentStack.widthAnchor).isActive = true
        }

        overlayHost?.removeFromSuperview()
        overlayHost = nil
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

        let sectionChanged = renderedSection != section
        let ids = displayedSubscriptions.map(\.id)
        if sectionChanged || ids != renderedSubscriptionIDs {
            tableView.reloadData()
        }
        renderedSubscriptionIDs = ids
        renderedWorkIDs = []
        if sectionChanged {
            tableView.scroll(.zero)
        }
        tableView.deselectAll(nil)
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
        isShowingSubscriptionList ? displayedSubscriptions.count : works.count
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        if isShowingSubscriptionList {
            guard row < displayedSubscriptions.count else { return nil }
            let cell: SubscriptionRowCellView
            if let reused = tableView.makeView(withIdentifier: SubscriptionRowCellView.reuseID, owner: self) as? SubscriptionRowCellView {
                cell = reused
            } else {
                cell = SubscriptionRowCellView(theme: theme)
                cell.identifier = SubscriptionRowCellView.reuseID
            }
            let sub = displayedSubscriptions[row]
            cell.configure(with: sub,
                           isLoading: model.loadingSubscriptionID == sub.id,
                           isActive: sub.subType.lowercased().contains("author") && model.subscriptionWorksTitle == sub.name)
            return cell
        }

        let cell: WorkRowCellView
        if let reused = tableView.makeView(withIdentifier: WorkRowCellView.reuseID, owner: self) as? WorkRowCellView {
            cell = reused
        } else {
            cell = WorkRowCellView(theme: theme)
            cell.identifier = WorkRowCellView.reuseID
        }
        let work = works[row]
        let textWidth = max(100, tableView.bounds.width - 45)
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
        if isShowingSubscriptionList { return 52 }
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
                             availableTextWidth: max(100, width - 45))
        sizingCell.frame = NSRect(x: 0, y: 0, width: width, height: 10_000)
        sizingCell.layoutSubtreeIfNeeded()
        return max(52, sizingCell.fittingSize.height)
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        let row = tableView.selectedRow
        guard row >= 0 else { return }

        if isShowingSubscriptionList {
            guard row < displayedSubscriptions.count else { return }
            let sub = displayedSubscriptions[row]
            let type = sub.subType.lowercased()
            if type.contains("author") || type.contains("user") {
                model.openSubscriptionAuthorWorks(subscriptionID: sub.id, author: sub.name)
            } else if type.contains("work") {
                model.selectWork(sub.id)
            }
            tableView.deselectAll(nil)
            return
        }

        guard row < works.count else { return }
        let id = works[row].id
        if model.selectedWorkID != id {
            model.selectWork(id)
        }
    }

    // The full text belongs in the expanded row, not in the hover overlay.
    func tableView(_ tableView: NSTableView, shouldShowCellExpansionFor tableColumn: NSTableColumn?, row: Int) -> Bool {
        false
    }

    // Swipe right on a row → Remove. Currently Reading clears the saved
    // progress; Offline deletes the download (cached chapters purge later).
    func tableView(_ tableView: NSTableView, rowActionsForRow row: Int,
                   edge: NSTableView.RowActionEdge) -> [NSTableViewRowAction] {
        guard edge == .leading, row < works.count else { return [] }
        let workID = works[row].id
        switch model.section {
        case .reading:
            let remove = NSTableViewRowAction(style: .destructive, title: "Remove") { [weak self] _, _ in
                self?.model.removeFromCurrentlyReading(workID)
                tableView.rowActionsVisible = false
            }
            return [remove]
        case .downloads:
            let remove = NSTableViewRowAction(style: .destructive, title: "Delete") { [weak self] _, _ in
                guard let self, appState.downloadedWorkIDs.contains(workID) else { return }
                appState.toggleDownload(workID)
                tableView.rowActionsVisible = false
            }
            return [remove]
        case .subscriptions where model.subscriptionSubTab == "new":
            let remove = NSTableViewRowAction(style: .destructive, title: "Remove") { [weak self] _, _ in
                self?.appState.removeNewWork(workID)
                tableView.rowActionsVisible = false
            }
            return [remove]
        default:
            return []
        }
    }
}
