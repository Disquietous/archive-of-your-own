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
    private let tableView = KeyNavTableView()

    private var chipsHost: NSView?
    private var filterPopover: NSPopover?
    private var variantHost: NSView?
    private var overlayHost: NSView?
    private var eyeButton: ToolButton?
    private var refreshButton: ToolButton?
    private var loadMoreButton: ToolButton?

    private var statusBar: NSView!
    private var statusLabel: NSTextField!
    private var statusSpinner: NSProgressIndicator!
    private var statusBarHeight: NSLayoutConstraint!

    private var inboxPrevButton: ToolButton?
    private var inboxNextButton: ToolButton?
    private var inboxPageField: NSTextField?
    private var inboxPageContainer: NSView?

    private var works: [Work] = []
    private var displayedSubscriptions: [USubscription] = []
    private var renderedSection: MacAppModel.Section?
    private var renderedWorkIDs: [String] = []
    private var renderedSubscriptionIDs: [String] = []
    private var expandedSummaries: Set<String> = []
    private var expandedTags: Set<String> = []
    private var renderedDensity: Density?
    private var renderedUIScale: Double?
    /// Width the rows were last measured at. Row heights depend on wrap width,
    /// and the first render happens before layout gives the table its real
    /// width — rows measured at the fallback width keep excess bottom space.
    private var lastLayoutWidth: CGFloat = 0
    private var isShowingSubscriptionList: Bool {
        model.section == .subscriptions
    }
    /// Measures off-screen rows for heightOfRow.
    private lazy var sizingCell = WorkRowCellView(theme: theme)
    private lazy var subscriptionSizingCell = SubscriptionRowCellView(theme: theme)
    private lazy var sortFilterMenu = SortFilterMenuController(theme: theme, model: model)

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

    // MARK: - Render

    private func render() {
        view.layer?.backgroundColor = theme.nsBg.cgColor
        toolbar.applyTheme()

        // Density and app text size change row metrics — drop the rendered-ID
        // caches so the table reloads and re-measures. (Reading them here also
        // makes the relay re-render when the settings change.)
        if renderedDensity != theme.density || renderedUIScale != theme.uiFontScale {
            renderedDensity = theme.density
            renderedUIScale = theme.uiFontScale
            renderedWorkIDs = []
            renderedSubscriptionIDs = []
        }

        let section = model.section
        switch section {
        case .browse:
            works = model.works(for: .browse)
            toolbar.configure(title: "Browse", sub: subtitleForNetworkList(count: works.count, loading: appState.isBrowsing))
            toolbar.setLeading([])
            toolbar.setTrailing([browseRefreshButton(), worksFilterButton(for: .browse), eyeToggleButton()])
            showWorksContent(section: section, header: nil,
                             overlay: networkOverlay(loading: appState.isBrowsing,
                                                     loadingMessage: "Fetching latest works…",
                                                     emptyIcon: "safari", emptyTitle: "Nothing here yet",
                                                     emptyMessage: "Connect and refresh to browse the newest works on the archive."))

        case .search:
            toolbar.configure(title: "Search", sub: model.search.formFields.isEmpty ? "Criteria" : "AO3 criteria")
            toolbar.setLeading([])
            toolbar.setTrailing([searchGoButton(), saveSearchButton(), reloadFieldsButton(), eyeToggleButton()])
            showVariant(SearchFormView(theme: theme, appState: appState, model: model), section: section)

        case .authorWorks:
            break

        case .reading, .history, .bookmarks, .downloads:
            works = model.works(for: section)
            let meta = sectionMeta(for: section)
            toolbar.configure(title: meta.title, sub: "\(works.count) · \(meta.sub)")
            toolbar.setLeading([])
            var trailing: [NSView] = [sortFilterMenu.makeButton(for: section), worksFilterButton(for: section)]
            if section == .reading && !works.isEmpty {
                trailing.insert(removeAllReadingButton(), at: 0)
            }
            toolbar.setTrailing(trailing)
            let empty = works.isEmpty
                ? AnyView(EmptyStateMac(theme: theme, icon: meta.empty.0, title: meta.empty.1, message: meta.empty.2))
                : nil
            showWorksContent(section: section, header: nil, overlay: empty)

        case .whatsNew:
            do {
                works = model.works(for: .whatsNew)
                let checkSub: String
                if works.isEmpty {
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
                buttons.append(worksFilterButton(for: .whatsNew))
                toolbar.setLeading([])
                toolbar.setTrailing(buttons)
                let overlay: AnyView?
                if !appState.isCheckingSubscriptions && works.isEmpty {
                    let checkStatus = appState.subscriptionCheckTask.statusMessage
                    overlay = AnyView(EmptyStateMac(theme: theme, icon: "bell",
                                                    title: "Nothing new",
                                                    message: checkStatus ?? "Updates from works and authors you follow appear here."))
                } else {
                    overlay = nil
                }
                showWorksContent(section: section, header: nil, overlay: overlay)
            }

        case .subscriptions:
            do {
                displayedSubscriptions = model.filteredSubscriptions
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
                let followingFilter = filterButton(key: "following", active: !model.subscriptionListFilter.isEmpty) { [theme, model] in
                    AnyView(SingleFieldFilterView(theme: theme, title: "Filter Following",
                                                  placeholder: "Name",
                                                  text: Binding(get: { model.subscriptionListFilter },
                                                                set: { model.subscriptionListFilter = $0 })))
                }
                toolbar.setLeading([])
                toolbar.setTrailing([followingFilter, ToolButton(theme: theme, symbol: "arrow.down.circle", tooltip: "Refresh list from AO3") { [weak self] in
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
                if let err = appState.subscriptionError, !err.isEmpty, !appState.isLoadingSubscriptions {
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

        case .inbox:
            let sub: String
            if appState.isLoadingInbox && appState.inboxMessages.isEmpty {
                sub = "Loading…"
            } else if appState.inboxUnreadCount > 0 {
                sub = "\(appState.inboxUnreadCount) unread"
            } else {
                sub = "\(appState.inboxMessages.count) messages"
            }
            toolbar.configure(title: "Inbox", sub: sub)
            toolbar.setLeading([])
            let inboxFilter = filterButton(key: "inbox", active: !model.inboxFilterAuthor.isEmpty
                                               || !model.inboxFilterWork.isEmpty
                                               || !model.inboxFilterText.isEmpty) { [theme, model] in
                AnyView(InboxFilterView(theme: theme, model: model))
            }
            toolbar.setTrailing([inboxFilter] + inboxToolbarButtons())
            showVariant(InboxView(theme: theme, appState: appState, model: model), section: section)

        case .fandoms:
            toolbar.configure(title: "Fandoms", sub: "\(model.followedFandoms.count) followed")
            toolbar.setLeading([])
            toolbar.setTrailing([filterButton(key: "fandoms", active: !model.fandomsListFilter.isEmpty) { [theme, model] in
                AnyView(SingleFieldFilterView(theme: theme, title: "Filter Fandoms",
                                              placeholder: "Fandom name",
                                              text: Binding(get: { model.fandomsListFilter },
                                                            set: { model.fandomsListFilter = $0 })))
            }])
            showVariant(FollowedFandomsView(theme: theme, model: model), section: section)

        case .authors:
            let count = model.followedAuthorNames.count + model.followedAuthors.count
            toolbar.configure(title: "Authors", sub: "\(count) followed")
            toolbar.setLeading([])
            toolbar.setTrailing([filterButton(key: "authors", active: !model.authorsListFilter.isEmpty) { [theme, model] in
                AnyView(SingleFieldFilterView(theme: theme, title: "Filter Authors",
                                              placeholder: "Username",
                                              text: Binding(get: { model.authorsListFilter },
                                                            set: { model.authorsListFilter = $0 })))
            }])
            showVariant(AuthorsList(theme: theme, appState: appState, model: model), section: section)

        case .stats:
            toolbar.configure(title: "Reading Stats", sub: "Counted on device")
            toolbar.setTrailing([])
            showVariant(StatsView(theme: theme, model: model), section: section)
        }
        renderedSection = section
        updateStatusBar(section: section)
    }

    private func updateStatusBar(section: MacAppModel.Section) {
        var message: String?
        var active = false

        switch section {
        case .whatsNew:
            if appState.subscriptionCheckTask.isReconnecting,
               let msg = appState.subscriptionCheckTask.statusMessage {
                message = msg
                active = true
            } else if appState.isCheckingSubscriptions {
                let done = appState.subscriptionCheckTotal - appState.subscriptionCheckRemaining
                message = "Checking \(done) of \(appState.subscriptionCheckTotal)"
                active = true
            } else if let msg = appState.subscriptionCheckTask.statusMessage, !msg.isEmpty {
                message = msg
            }
        case .subscriptions:
            if appState.isLoadingSubscriptions {
                message = "Refreshing subscriptions from AO3…"
                active = true
            }
        case .inbox:
            if appState.isCheckingInbox {
                message = "Checking for new messages…"
                active = true
            } else if appState.isLoadingInbox {
                message = "Loading inbox…"
                active = true
            } else if let msg = appState.inboxCheckTask.statusMessage, !msg.isEmpty {
                message = msg
            }
        case .browse:
            if appState.isBrowsing {
                message = "Fetching latest works…"
                active = true
            }
        default:
            break
        }

        if let message {
            statusLabel.stringValue = message
            statusLabel.textColor = theme.nsInk3
            statusBar.layer?.backgroundColor = theme.nsSurface.cgColor
            statusBarHeight.constant = 26
            statusBar.isHidden = false
            if active {
                statusSpinner.startAnimation(nil)
                statusSpinner.isHidden = false
            } else {
                statusSpinner.stopAnimation(nil)
                statusSpinner.isHidden = true
            }
        } else {
            statusBarHeight.constant = 0
            statusBar.isHidden = true
            statusSpinner.stopAnimation(nil)
        }
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

    private func inboxToolbarButtons() -> [NSView] {
        let prev = inboxPrevButton ?? ToolButton(theme: theme, symbol: "chevron.left", tooltip: "Previous page") { [weak self] in
            guard let self else { return }
            let page = self.appState.inboxPage
            guard page > 1 else { return }
            self.appState.loadCachedInbox(page: page - 1)
        }
        inboxPrevButton = prev
        prev.isEnabled = appState.inboxPage > 1

        let next = inboxNextButton ?? ToolButton(theme: theme, symbol: "chevron.right", tooltip: "Next page") { [weak self] in
            guard let self else { return }
            guard self.appState.inboxHasMore else { return }
            self.appState.loadCachedInbox(page: self.appState.inboxPage + 1)
        }
        inboxNextButton = next
        next.isEnabled = appState.inboxHasMore

        let container: NSView
        if let existing = inboxPageContainer {
            container = existing
        } else {
            let label = NSTextField(labelWithString: "Page")
            label.font = MacFont.ui(11, weight: .medium)
            label.textColor = theme.nsInk3
            label.translatesAutoresizingMaskIntoConstraints = false

            let field = NSTextField()
            field.font = MacFont.ui(12, weight: .medium)
            field.alignment = .center
            field.isBordered = true
            field.isBezeled = true
            field.bezelStyle = .roundedBezel
            field.translatesAutoresizingMaskIntoConstraints = false
            field.target = self
            field.action = #selector(inboxPageFieldCommitted)
            NSLayoutConstraint.activate([
                field.widthAnchor.constraint(equalToConstant: 36),
                field.heightAnchor.constraint(equalToConstant: 22),
            ])
            inboxPageField = field

            let stack = NSStackView(views: [label, field])
            stack.orientation = .horizontal
            stack.spacing = 4
            stack.alignment = .centerY
            stack.translatesAutoresizingMaskIntoConstraints = false
            inboxPageContainer = stack
            container = stack
        }

        inboxPageField?.stringValue = "\(appState.inboxPage)"

        let refresh = ToolButton(theme: theme, symbol: "arrow.clockwise", tooltip: "Check for new messages") { [weak self] in
            guard let self else { return }
            Task { await self.appState.checkInbox() }
        }

        return [prev, container, next, refresh]
    }

    @objc private func inboxPageFieldCommitted() {
        guard let text = inboxPageField?.stringValue,
              let page = UInt32(text), page >= 1 else {
            inboxPageField?.stringValue = "\(appState.inboxPage)"
            return
        }
        appState.loadCachedInbox(page: page)
    }

    // MARK: - Per-section filter popover

    /// Memoized per key: render() rebuilds the toolbar constantly, and a
    /// recreated button would yank the popover's anchor out of the view
    /// hierarchy — dismissing the dialog the moment it opens (or on the
    /// first keystroke, which re-renders via the filter state).
    private var filterButtons: [String: ToolButton] = [:]

    /// Toolbar button opening the section's tailored filter dialog; lit
    /// (accent fill) while a filter is active.
    private func filterButton(key: String, active: Bool, content: @escaping () -> AnyView) -> ToolButton {
        if let existing = filterButtons[key] {
            existing.isOn = active
            return existing
        }
        var anchor: ToolButton!
        let button = ToolButton(theme: theme, symbol: "line.3.horizontal.decrease.circle",
                                tooltip: "Filter this list") { [weak self] in
            guard let self, let anchor else { return }
            if let popover = filterPopover, popover.isShown {
                popover.close()
                filterPopover = nil
                return
            }
            let popover = NSPopover()
            popover.behavior = .transient
            let host = NSHostingController(rootView: content())
            popover.contentViewController = host
            // Size the popover to the SwiftUI content BEFORE showing — an
            // unsized hosting controller makes NSPopover pick an arbitrary
            // frame and misplace the dialog relative to its anchor.
            host.view.layoutSubtreeIfNeeded()
            popover.contentSize = host.view.fittingSize
            popover.show(relativeTo: anchor.bounds, of: anchor, preferredEdge: .maxY)
            filterPopover = popover
        }
        button.isOn = active
        anchor = button
        filterButtons[key] = button
        return button
    }

    private func worksFilterButton(for section: MacAppModel.Section) -> ToolButton {
        filterButton(key: "works-\(section)",
                     active: model.workListFilter(for: section).isActive) { [theme, model] in
            AnyView(WorkListFilterView(theme: theme, model: model, section: section))
        }
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
            // Same rows — only move the selection highlight and bookmark
            // indicator. Reloading here replaces every cell and makes
            // expand/collapse look like a flash. (Reading bookmarkedWorkIDs
            // also re-renders the moment a bookmark toggles.)
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

        // Read the drill-in identity and loading state on EVERY render path,
        // not just the same-rows branch: the reload path's cell configuration
        // happens lazily outside this tracked closure, so without these reads
        // a reload render left the relay blind to selection changes — the
        // highlight then waited for cells to scroll off-screen and re-make.
        let activeID = model.subscriptionWorksSubId
        let activeType = model.subscriptionWorksSubType
        let loadingID = model.loadingSubscriptionID

        let sectionChanged = renderedSection != section
        let ids = displayedSubscriptions.map(\.id)
        if sectionChanged || ids != renderedSubscriptionIDs {
            tableView.reloadData()
        } else {
            // Same rows — reconfigure the visible cells so the selection
            // highlight and "Fetching works…" state move immediately.
            tableView.enumerateAvailableRowViews { [weak self] _, row in
                guard let self, row < displayedSubscriptions.count,
                      let cell = tableView.view(atColumn: 0, row: row, makeIfNecessary: false) as? SubscriptionRowCellView
                else { return }
                let sub = displayedSubscriptions[row]
                cell.configure(with: sub,
                               isLoading: loadingID == sub.id,
                               isActive: activeID == sub.id && activeType == normalizedSubType(sub))
            }
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
                           isActive: model.subscriptionWorksSubId == sub.id
                               && model.subscriptionWorksSubType == normalizedSubType(sub))
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
                       bookmarked: appState.bookmarkedWorkIDs.contains(work.id),
                       summaryExpanded: expandedSummaries.contains(work.id),
                       tagsExpanded: expandedTags.contains(work.id),
                       availableTextWidth: textWidth)
        cell.onToggleSummary = { [weak self] in
            self?.toggleSummary(workID: work.id)
        }
        cell.onToggleTags = { [weak self] in
            self?.toggleTags(workID: work.id)
        }
        cell.onToggleBookmark = { [weak self] in
            self?.appState.toggleBookmark(work.id)
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

    private func toggleTags(workID: String) {
        if expandedTags.contains(workID) {
            expandedTags.remove(workID)
        } else {
            expandedTags.insert(workID)
        }
        guard let row = works.firstIndex(where: { $0.id == workID }) else { return }
        tableView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
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

    /// Row heights come from the cells' own measurement. The automatic
    /// row-height engine was measured (see git history) applying height
    /// changes on reload only upward — a collapsed summary's shorter,
    /// correctly-measured height was silently discarded, so rows never shrank.
    func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
        if isShowingSubscriptionList {
            guard row < displayedSubscriptions.count else { return 52 }
            // Measure so the centered text block keeps its padding at any
            // app text size / density instead of clipping against a fixed 52.
            subscriptionSizingCell.configure(with: displayedSubscriptions[row],
                                             isLoading: false, isActive: false)
            return max(44, subscriptionSizingCell.fittingSize.height)
        }
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
                             tagsExpanded: expandedTags.contains(work.id),
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
            if type.contains("author") || type.contains("user") || type.contains("series") {
                model.openSubscriptionAuthorWorks(subscriptionID: sub.id, author: sub.name,
                                                  subType: normalizedSubType(sub))
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

    @objc private func rowClicked() {
        guard !isShowingSubscriptionList else { return }
        let row = tableView.clickedRow
        guard row >= 0, row < works.count else { return }
        let id = works[row].id
        // selectionDidChange already handled a changed selection; this covers
        // the stale-selection re-click and refocusing the detail over a reader.
        if model.selectedWorkID != id || model.readerOpen {
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
        case .whatsNew:
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

// MARK: - Row context menu

extension ListPaneViewController: NSMenuDelegate {
    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let row = tableView.clickedRow
        guard row >= 0 else { return }

        if isShowingSubscriptionList {
            guard row < displayedSubscriptions.count else { return }
            let sub = displayedSubscriptions[row]
            let type = sub.subType.lowercased()
            if type.contains("author") || type.contains("user") || type.contains("series") {
                menu.addItem(menuItem("Show Works", #selector(menuShowSubscriptionWorks(_:)), row))
            }
            menu.addItem(menuItem("Copy AO3 Link", #selector(menuCopySubscriptionLink(_:)), row))
            return
        }

        guard row < works.count else { return }
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
        if appState.downloadedWorkIDs.contains(work.id) {
            menu.addItem(menuItem("Export as EPUB…", #selector(menuExportEpub(_:)), row))
        }

        // Section-specific destructive action (the swipe action's menu twin).
        switch model.section {
        case .reading:
            menu.addItem(.separator())
            menu.addItem(menuItem("Remove from Currently Reading", #selector(menuRemoveFromReading(_:)), row))
        case .whatsNew:
            menu.addItem(.separator())
            menu.addItem(menuItem("Remove from What’s New", #selector(menuRemoveFromNew(_:)), row))
        default:
            break
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

    @objc private func menuExportEpub(_ sender: NSMenuItem) {
        guard let work = clickedWork(sender) else { return }
        EpubExporter.export(work: work, appState: appState)
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

    @objc private func menuRemoveFromReading(_ sender: NSMenuItem) {
        guard let work = clickedWork(sender) else { return }
        model.removeFromCurrentlyReading(work.id)
    }

    @objc private func menuRemoveFromNew(_ sender: NSMenuItem) {
        guard let work = clickedWork(sender) else { return }
        appState.removeNewWork(work.id)
    }

    @objc private func menuShowSubscriptionWorks(_ sender: NSMenuItem) {
        guard sender.tag >= 0, sender.tag < displayedSubscriptions.count else { return }
        let sub = displayedSubscriptions[sender.tag]
        model.openSubscriptionAuthorWorks(subscriptionID: sub.id, author: sub.name,
                                          subType: normalizedSubType(sub))
    }

    /// The drill-in/cache key for a subscription ("author" or "series").
    private func normalizedSubType(_ sub: USubscription) -> String {
        sub.subType.lowercased().contains("series") ? "series" : "author"
    }

    /// Star button on the search toolbar — names and saves the current criteria.
    fileprivate func saveSearchButton() -> ToolButton {
        ToolButton(theme: theme, symbol: "star", tooltip: "Save this search") { [weak self] in
            guard let self else { return }
            let alert = NSAlert()
            alert.messageText = "Save Search"
            alert.informativeText = "The current criteria will appear under Saved Searches in the sidebar."
            let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
            field.placeholderString = "Name"
            field.stringValue = model.search.queryText
            alert.accessoryView = field
            alert.addButton(withTitle: "Save")
            alert.addButton(withTitle: "Cancel")
            alert.window.initialFirstResponder = field
            guard alert.runModal() == .alertFirstButtonReturn else { return }
            let name = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty else { return }
            model.search.saveCurrentSearch(named: name, appState: appState)
        }
    }

    @objc private func menuCopySubscriptionLink(_ sender: NSMenuItem) {
        guard sender.tag >= 0, sender.tag < displayedSubscriptions.count else { return }
        let sub = displayedSubscriptions[sender.tag]
        let type = sub.subType.lowercased()
        let url: String
        if type.contains("author") || type.contains("user") {
            url = "https://archiveofourown.org/users/\(sub.id)"
        } else if type.contains("series") {
            url = "https://archiveofourown.org/series/\(sub.id)"
        } else {
            url = "https://archiveofourown.org/works/\(sub.id)"
        }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(url, forType: .string)
    }
}
