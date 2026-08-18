import AppKit
import SwiftUI

/// Right pane shell: 52px toolbar + either the work detail or the in-place
/// reader, with the privacy dot, reading-settings popover, and the floating
/// immersive exit button.
final class ReadPaneViewController: NSViewController {
    private let theme: AppTheme
    private let appState: AppState
    private let model: MacAppModel

    private let toolbar: PaneToolbarView
    private let container = NSView()
    private let privacyDot = NSView()
    private let immersiveExit = NSButton()

    private var backButton: ToolButton!
    private var settingsButton: ToolButton!
    private var immersiveButton: ToolButton!
    private var bookmarkButton: ToolButton!
    private var commentsButton: ToolButton!
    private var chaptersButton: ToolButton!
    private var chaptersPopover: NSPopover?
    // Detail-mode work actions (the detail view's buttons live in this
    // header toolbar, not in the scroll body).
    private var startReadingButton: ToolButton!
    private var downloadButton: ToolButton!
    private var readingListButton: ToolButton!
    private var subscribeButton: ToolButton!
    private var kudosButton: ToolButton!
    private var workCommentsButton: ToolButton!
    private var editBookmarkButton: ToolButton!
    private var readingListPopover: NSPopover?

    private let readerController: ReaderViewController
    private var resultsController: SearchResultsViewController?
    private var collectionSplitController: NSSplitViewController?
    private var pagerHost: NSHostingView<SearchPagerView>?
    private var resultsBackButton: ToolButton!
    private var detailHost: NSHostingView<AnyView>?
    private var emptyHost: NSHostingView<AnyView>?

    private enum Mode: Equatable {
        case empty, searchForm, searchResults, subscriptionWorks(String),
             authorCollections(String), detail(String), reading(String, Int), inboxThread(UInt64),
             settings, scopeForm, scopeResults, collectionSplit
    }

    private var renderedMode: Mode?

    init(theme: AppTheme, appState: AppState, model: MacAppModel) {
        self.theme = theme
        self.appState = appState
        self.model = model
        self.toolbar = PaneToolbarView(theme: theme)
        self.readerController = ReaderViewController(theme: theme, appState: appState, model: model)
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override func loadView() {
        let root = NSView()
        root.wantsLayer = true
        root.setContentCompressionResistancePriority(.init(1), for: .horizontal)

        backButton = ToolButton(theme: theme, symbol: "arrow.left", tooltip: "Back to details") { [weak self] in
            self?.model.closeReader()
        }
        settingsButton = ToolButton(theme: theme, symbol: "textformat.size", tooltip: "Reading settings") { [weak self] in
            self?.toggleSettingsPopover()
        }
        immersiveButton = ToolButton(theme: theme, symbol: "safari", tooltip: "Immersive reading") { [weak self] in
            self?.model.immersive.toggle()
        }
        bookmarkButton = ToolButton(theme: theme, symbol: "bookmark", tooltip: "Bookmark") { [weak self] in
            guard let self, let id = model.selectedWorkID else { return }
            appState.toggleBookmark(id)
        }
        commentsButton = ToolButton(theme: theme, symbol: "bubble.right", tooltip: "Chapter comments") { [weak self] in
            self?.showChapterComments()
        }
        chaptersButton = ToolButton(theme: theme, symbol: "list.bullet", tooltip: "Chapters") { [weak self] in
            self?.toggleChaptersPopover()
        }
        resultsBackButton = ToolButton(theme: theme, symbol: "arrow.left", tooltip: "Back to results") { [weak self] in
            self?.model.backToResults()
        }
        startReadingButton = ToolButton(theme: theme, symbol: "book", tooltip: "Start reading") { [weak self] in
            guard let self, let id = model.selectedWorkID else { return }
            model.openReader(id, chapter: max(0, (appState.progressMap[id]?.chapter ?? 1) - 1))
        }
        downloadButton = ToolButton(theme: theme, symbol: "arrow.down.circle", tooltip: "Download for offline") { [weak self] in
            guard let self, let id = model.selectedWorkID else { return }
            appState.toggleDownload(id)
        }
        readingListButton = ToolButton(theme: theme, symbol: "books.vertical", tooltip: "Add to reading list") { [weak self] in
            self?.toggleReadingListPopover()
        }
        subscribeButton = ToolButton(theme: theme, symbol: "bell", tooltip: "Subscribe to this work on AO3") { [weak self] in
            guard let self, let id = model.selectedWorkID else { return }
            appState.toggleWorkSubscription(id)
        }
        kudosButton = ToolButton(theme: theme, symbol: "heart", tooltip: "Leave kudos on AO3") { [weak self] in
            guard let self, let id = model.selectedWorkID else { return }
            appState.giveKudos(id)
        }
        // Kudos-given disables the button, but the heart's color IS the
        // state display — AppKit's automatic disabled dim would wash the
        // full-red confirmation down to what reads as the faded state.
        (kudosButton.cell as? NSButtonCell)?.imageDimsWhenDisabled = false
        workCommentsButton = ToolButton(theme: theme, symbol: "bubble.right", tooltip: "Comments") { [weak self] in
            self?.showWorkComments()
        }
        editBookmarkButton = ToolButton(theme: theme, symbol: "square.and.pencil",
                                        tooltip: "Edit bookmark — notes, tags, sync to AO3") { [weak self] in
            self?.showBookmarkEditSheet()
        }

        addChild(readerController)

        toolbar.translatesAutoresizingMaskIntoConstraints = false
        container.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(toolbar)
        root.addSubview(container)

        privacyDot.wantsLayer = true
        privacyDot.layer?.cornerRadius = 4
        privacyDot.toolTip = "Private connection"
        privacyDot.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(privacyDot)

        immersiveExit.isBordered = false
        immersiveExit.wantsLayer = true
        immersiveExit.layer?.cornerRadius = 9
        immersiveExit.layer?.borderWidth = 1
        immersiveExit.image = NSImage(systemSymbolName: "chevron.left", accessibilityDescription: "Exit immersive")?
            .withSymbolConfiguration(.init(pointSize: 13, weight: .semibold))
        immersiveExit.toolTip = "Exit immersive (Esc)"
        immersiveExit.target = self
        immersiveExit.action = #selector(exitImmersive)
        immersiveExit.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(immersiveExit)

        toolbarTop = toolbar.topAnchor.constraint(equalTo: root.topAnchor)
        NSLayoutConstraint.activate([
            toolbarTop,
            toolbar.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            toolbar.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            container.topAnchor.constraint(equalTo: toolbar.bottomAnchor),
            container.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            container.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            container.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            privacyDot.topAnchor.constraint(equalTo: toolbar.bottomAnchor, constant: 10),
            privacyDot.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -18),
            privacyDot.widthAnchor.constraint(equalToConstant: 8),
            privacyDot.heightAnchor.constraint(equalToConstant: 8),
            immersiveExit.topAnchor.constraint(equalTo: toolbar.topAnchor, constant: 9),
            immersiveExit.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 14),
            immersiveExit.widthAnchor.constraint(equalToConstant: 34),
            immersiveExit.heightAnchor.constraint(equalToConstant: 34),
        ])
        view = root

        ObservationRelay.track { [weak self] in
            self?.render()
        }

        // App-wide reading keys: ← / → change chapters while reading; Escape
        // backs out of the innermost context (immersive → reader → selection
        // → drill-in). Never fires while typing in an editable text control
        // or while a sheet is up.
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self,
                  let window = view.window,
                  event.window === window,
                  window.attachedSheet == nil
            else { return event }
            if let editor = window.firstResponder as? NSTextView, editor.isEditable {
                return event
            }
            let hasModifiers = !event.modifierFlags.intersection([.command, .option, .control]).isEmpty
            switch event.keyCode {
            case 123 where model.readerOpen && !hasModifiers: // ←
                readerController.goToAdjacentChapter(-1)
                return nil
            case 124 where model.readerOpen && !hasModifiers: // →
                readerController.goToAdjacentChapter(1)
                return nil
            case 53 where !hasModifiers: // Escape
                // Sheets (settings, comments, bookmark edit) and popovers
                // own Escape while they're up.
                if presentedViewControllers?.isEmpty == false { return event }
                if let popover = chaptersPopover, popover.isShown { return event }
                return model.escapeInnermost() ? nil : event
            default:
                return event
            }
        }
    }

    deinit {
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
    }

    private var keyMonitor: Any?
    private var toolbarTop: NSLayoutConstraint!
    private var subscriptionCloseBtn: ToolButton?
    private var readingListCloseBtn: ToolButton?
    private var fandomCloseBtn: ToolButton?
    private var fandomSearchBtn: ToolButton?
    private var fandomLibraryBackBtn: ToolButton?
    private var filterButtons: [String: ToolButton] = [:]
    private var filterPopover: NSPopover?

    /// Same filter-popover machinery as ListPaneViewController: a cached
    /// toggle button anchoring a transient popover, sized to its SwiftUI
    /// content before showing.
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

    /// Header filter for the bookmark search results — the work-list
    /// fields plus the bookmark's own (bookmarked by, note, date).
    private func bookmarksFilterButton() -> ToolButton {
        let button = filterButton(key: "bookmark-search",
                                  active: model.search.bookmarkListFilter.isActive) { [theme, model] in
            AnyView(BookmarkListFilterView(theme: theme, model: model))
        }
        // A client-side sieve over the fetched rows — make sure it can't be
        // mistaken for a server-side search refinement.
        button.toolTip = "Filter the fetched results (this page only)"
        return button
    }

    private func worksFilterButton(for section: MacAppModel.Section) -> ToolButton {
        let button = filterButton(key: "works-\(section)",
                                  active: model.workListFilter(for: section).isActive) { [theme, model] in
            AnyView(WorkListFilterView(theme: theme, model: model, section: section))
        }
        if section == .search {
            // This is a client-side sieve over the fetched rows — make sure
            // it can't be mistaken for a server-side search refinement.
            button.toolTip = "Filter the fetched results (this page only)"
        }
        return button
    }

    /// The scraped AO3 sort-column field, when the form has one.
    private func searchSortField() -> UFormField? {
        model.search.formFields.first { $0.name.hasSuffix("[sort_column]") }
    }

    /// Server-side sort menu for search results: options come from the
    /// scraped form's sort fields; picking one rewrites the criteria and
    /// re-runs the query, so re-sorting no longer means a round-trip back
    /// to the form.
    private func searchSortButton() -> ToolButton {
        var anchor: ToolButton!
        let button = ToolButton(theme: theme, symbol: "arrow.up.arrow.down",
                                tooltip: "Sort results (re-runs the search)") { [weak self] in
            guard let self, let anchor else { return }
            showSearchSortMenu(from: anchor)
        }
        anchor = button
        return button
    }

    private func showSearchSortMenu(from anchor: NSView) {
        guard let sortField = searchSortField() else { return }
        let search = model.search
        let menu = NSMenu()
        menu.autoenablesItems = false

        let sortHeader = NSMenuItem(title: "Sort By", action: nil, keyEquivalent: "")
        sortHeader.isEnabled = false
        menu.addItem(sortHeader)
        // AO3 pre-selects a default when the field is unset locally.
        let currentSort = search.fieldValues[sortField.name]
            ?? sortField.options.first { $0.selected }?.value ?? ""
        for option in sortField.options {
            let title = option.label.trimmingCharacters(in: .whitespaces)
            guard !title.isEmpty else { continue }
            let item = NSMenuItem(title: title, action: #selector(searchSortChosen(_:)), keyEquivalent: "")
            item.target = self
            item.state = option.value == currentSort ? .on : .off
            item.representedObject = [sortField.name, option.value]
            menu.addItem(item)
        }

        if let directionField = model.search.formFields.first(where: { $0.name.hasSuffix("[sort_direction]") }) {
            menu.addItem(.separator())
            let directionHeader = NSMenuItem(title: "Direction", action: nil, keyEquivalent: "")
            directionHeader.isEnabled = false
            menu.addItem(directionHeader)
            let currentDirection = search.fieldValues[directionField.name]
                ?? directionField.options.first { $0.selected }?.value ?? ""
            for option in directionField.options {
                let title = option.label.trimmingCharacters(in: .whitespaces)
                guard !title.isEmpty else { continue }
                let item = NSMenuItem(title: title, action: #selector(searchSortChosen(_:)), keyEquivalent: "")
                item.target = self
                item.state = option.value == currentDirection ? .on : .off
                item.representedObject = [directionField.name, option.value]
                menu.addItem(item)
            }
        }

        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: anchor.bounds.height + 4), in: anchor)
    }

    @objc private func searchSortChosen(_ sender: NSMenuItem) {
        guard let pair = sender.representedObject as? [String], pair.count == 2 else { return }
        model.search.fieldValues[pair[0]] = pair[1]
        model.search.performSearch(appState)
    }
    private var authorRefreshBtn: LabelToolButton?
    private var subscriptionRefreshBtn: LabelToolButton?
    private lazy var sortFilterMenu = SortFilterMenuController(theme: theme, model: model)
    private var detailRefreshBtn: ToolButton?

    /// The pager, hosted for the toolbar. The toolbar sits in the window's
    /// titlebar band (fullSizeContentView), and an NSHostingView there
    /// inherits a top safe-area inset that shoves the SwiftUI content below
    /// the bar's midline — the same mechanism the Tor overlay hit. Clearing
    /// safeAreaRegions makes it center like the AppKit ToolButtons.
    private func makePagerHost() -> NSHostingView<SearchPagerView> {
        if let pagerHost { return pagerHost }
        let host = NSHostingView(rootView: SearchPagerView(theme: theme, appState: appState, model: model))
        host.safeAreaRegions = []
        pagerHost = host
        return host
    }

    private var ao3Btn: LabelToolButton?
    private var ao3ButtonURL: URL?

    /// The header's "Ao3" pill: opens the shown entity's archive page in
    /// the user's configured link app. One cached instance — only one of
    /// the entity headers (work, collection, tag) is ever visible, and the
    /// URL is re-set on every render pass.
    private func ao3Button(url: URL?, tooltip: String) -> LabelToolButton {
        let button = ao3Btn ?? LabelToolButton(theme: theme) { [weak self] in
            guard let self, let url = ao3ButtonURL else { return }
            ExternalLinkOpener.open(url, bridge: appState.bridge)
        }
        ao3Btn = button
        ao3ButtonURL = url
        button.configure(title: "Ao3", symbol: "arrow.up.right", tooltip: tooltip)
        return button
    }

    private var requestProgressHost: NSHostingView<RequestProgressView>?

    /// Show/hide the request-progress banner over this pane's content area,
    /// bound to one tracked operation id (request-tracking standard). The
    /// host is a sibling of `container` added after it, so the content
    /// swaps `show(mode:)` performs inside the container can never cover
    /// it. Created on show and torn down on hide so its poll timer only
    /// runs while the tracked operation is in flight.
    private func setRequestProgressOverlay(_ opID: UInt64?) {
        guard let opID else {
            requestProgressHost?.removeFromSuperview()
            requestProgressHost = nil
            return
        }
        guard requestProgressHost == nil else { return }
        let host = NSHostingView(rootView: RequestProgressView(theme: theme, appState: appState, opID: opID))
        host.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(host)
        NSLayoutConstraint.activate([
            host.topAnchor.constraint(equalTo: container.topAnchor, constant: 10),
            host.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 16),
            host.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -16),
        ])
        requestProgressHost = host
    }

    private var readerRefreshBtn: ToolButton?

    /// Reader header: refetch the chapters from AO3, bypassing the caches —
    /// picks up chapter text that changed or arrived after the original fetch.
    private func readerRefreshButton() -> ToolButton {
        let button = readerRefreshBtn ?? ToolButton(theme: theme, symbol: "arrow.clockwise",
                                                    tooltip: "Refresh chapter from AO3") { [weak self] in
            self?.readerController.refreshChaptersFromAO3()
        }
        readerRefreshBtn = button
        return button
    }

    /// Detail header: re-fetch the work's current details from AO3.
    private func detailRefreshButton() -> ToolButton {
        let button = detailRefreshBtn ?? ToolButton(theme: theme, symbol: "arrow.clockwise",
                                                    tooltip: "Refresh details from AO3") { [weak self] in
            guard let self, let id = model.selectedWorkID else { return }
            Task { @MainActor in await self.appState.refreshWorkMetadata(id) }
        }
        detailRefreshBtn = button
        return button
    }

    private func subscriptionCloseButton() -> ToolButton {
        let button = subscriptionCloseBtn ?? ToolButton(theme: theme, symbol: "xmark", tooltip: "Close works list") { [weak self] in
            self?.model.closeSubscriptionWorks()
        }
        subscriptionCloseBtn = button
        return button
    }

    private func readingListCloseButton() -> ToolButton {
        let button = readingListCloseBtn ?? ToolButton(theme: theme, symbol: "xmark", tooltip: "Close list") { [weak self] in
            self?.model.closeReadingList()
        }
        readingListCloseBtn = button
        return button
    }

    private var authorProfileBtn: ToolButton?
    private var authorSubscribeBtn: ToolButton?

    /// The author the drill-in toolbar buttons act on — set on every render
    /// pass so the cached buttons' closures always target the current author.
    private var drillInAuthorUsername: String?

    /// Bell button for the author drill-ins: subscribe/unsubscribe on AO3.
    /// Symbol and tooltip track the live subscription state each render.
    private func authorSubscribeButton(username: String) -> ToolButton {
        let button = authorSubscribeBtn ?? ToolButton(theme: theme, symbol: "bell",
                                                      tooltip: "Subscribe") { [weak self] in
            guard let self, let user = drillInAuthorUsername else { return }
            appState.toggleAuthorSubscription(user)
        }
        authorSubscribeBtn = button
        let subscribed = appState.isSubscribedToAuthor(username)
        button.setSymbol(subscribed ? "bell.fill" : "bell")
        button.tintOverride = subscribed ? theme.nsAccent : nil
        button.toolTip = subscribed
            ? "Unsubscribe from \(username) on AO3"
            : "Subscribe to \(username) on AO3"
        button.isEnabled = !appState.isUserActionBusy("sub", username)
        return button
    }

    /// Person button for the subscriptions drill-in: opens the two-pane
    /// author view (profile in the list pane, their lists here).
    private func authorProfileButton() -> ToolButton {
        let button = authorProfileBtn ?? ToolButton(theme: theme, symbol: "person.crop.circle",
                                                    tooltip: "Show author profile") { [weak self] in
            guard let self, let user = drillInAuthorUsername else { return }
            model.openAuthorProfile(user)
        }
        authorProfileBtn = button
        return button
    }

    /// The subscribe/profile buttons for an author drill-in header, in
    /// trailing-order. Subscribe needs a signed-in AO3 session; the profile
    /// card is public data and always available.
    private func authorHeaderButtons(username: String) -> [NSView] {
        drillInAuthorUsername = username
        var buttons: [NSView] = []
        if appState.ao3Username != nil {
            buttons.append(authorSubscribeButton(username: username))
        }
        buttons.append(authorProfileButton())
        return buttons
    }

    // MARK: - Search pane buttons (the list pane is collapsed in Search,
    // so the form's actions live in this pane's header)

    private var searchBackBtn: ToolButton?
    private var searchGoBtn: ToolButton?
    private var reloadCriteriaBtn: ToolButton?
    private var scopeTabs: ScopeTabsView?
    private var searchSourceBtn: ToolButton?
    private var searchEyeBtn: ToolButton?

    /// The search scope tabs living where the "Search" title used to be.
    /// One instance for the pane's lifetime; render() re-reads the model's
    /// scope into it every pass (observable input, per the relay rule).
    private func scopeTabsView() -> ScopeTabsView {
        let tabs = scopeTabs ?? {
            let view = ScopeTabsView(theme: theme)
            view.onSelect = { [weak self] scope in
                guard let self else { return }
                self.model.search.setScope(scope)
            }
            return view
        }()
        scopeTabs = tabs
        return tabs
    }

    /// Library/AO3 source toggle: internaldrive = only the app's database,
    /// globe = full search on AO3.
    private func searchSourceButton() -> ToolButton {
        let button = searchSourceBtn ?? ToolButton(theme: theme, symbol: "internaldrive",
                                                   tooltip: "Search source") { [weak self] in
            guard let self else { return }
            model.search.searchLibraryOnly.toggle()
        }
        searchSourceBtn = button
        let libraryOnly = model.search.searchLibraryOnly
        button.setSymbol(libraryOnly ? "internaldrive" : "globe")
        button.toolTip = libraryOnly
            ? "Searching your library only — click to search AO3"
            : "Searching AO3 — click to search only your library"
        button.isOn = !libraryOnly
        return button
    }

    /// Split collection subtitle: the two listings' own totals, once known.
    private func splitCollectionSubtitle(_ search: MacSearchModel) -> String? {
        var parts: [String] = []
        if let works = search.totalWorks {
            parts.append(works == 1 ? "1 work" : "\(works) works")
        }
        if let items = search.bookmarksTotal {
            parts.append(items == 1 ? "1 bookmarked item" : "\(items) bookmarked items")
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    /// Results subtitle per scope: works-style results reuse the pager
    /// subtitle; the others report their own hit counts.
    private func scopeResultsSubtitle(_ search: MacSearchModel) -> String? {
        switch search.scope {
        case .works:
            let parts = [model.searchDisplayTitle, search.resultsSubtitle].compactMap { $0 }
            return parts.isEmpty ? nil : parts.joined(separator: " · ")
        case .bookmarks:
            var parts: [String] = []
            // Paged AO3 results carry the page position; library hits don't.
            if case .bookmarkSearch = search.activeQuery {
                parts.append(search.totalPages > 1
                    ? "Page \(search.currentPage) of \(search.totalPages)"
                    : "Page \(search.currentPage)")
            }
            if search.bookmarkListFilter.isActive {
                parts.append("\(search.filteredBookmarkHits.count) of \(search.bookmarkHits.count) bookmarks")
            } else {
                let total = search.totalWorks.map(Int.init) ?? search.bookmarkHits.count
                parts.append(total == 1 ? "1 bookmark" : "\(total) bookmarks")
            }
            return parts.joined(separator: " · ")
        case .tags:
            return search.tagHits.count == 1 ? "1 tag" : "\(search.tagHits.count) tags"
        case .users:
            return search.userHits.count == 1 ? "1 user" : "\(search.userHits.count) users"
        case .collections:
            let count = search.collectionHits.count == 1
                ? "1 collection" : "\(search.collectionHits.count) collections"
            // Paged AO3 results carry the page position; library hits don't.
            if case .collectionsIndex = search.activeQuery, let sub = search.resultsSubtitle {
                return "\(sub) · \(count)"
            }
            return count
        }
    }

    private func searchFormBackButton() -> ToolButton {
        let button = searchBackBtn ?? ToolButton(theme: theme, symbol: "arrow.left",
                                                 tooltip: "Back to search criteria") { [weak self] in
            self?.model.search.returnToForm()
        }
        searchBackBtn = button
        return button
    }

    private func searchGoButton() -> ToolButton {
        let button = searchGoBtn ?? ToolButton(theme: theme, symbol: "magnifyingglass",
                                               tooltip: "Search") { [weak self] in
            guard let self else { return }
            model.search.performScopedSearch(appState)
        }
        searchGoBtn = button
        button.isOn = true
        return button
    }

    private func reloadCriteriaButton() -> ToolButton {
        let button = reloadCriteriaBtn ?? ToolButton(theme: theme, symbol: "arrow.clockwise",
                                                     tooltip: "Reload search criteria from AO3") { [weak self] in
            guard let self else { return }
            Task { await self.model.search.scrapeForm(self.appState) }
        }
        reloadCriteriaBtn = button
        return button
    }

    private func searchEyeButton() -> ToolButton {
        let eye = searchEyeBtn ?? ToolButton(theme: theme, symbol: "eye",
                                             tooltip: "Hide explicit") { [weak self] in
            self?.model.hideExplicit.toggle()
        }
        searchEyeBtn = eye
        eye.isOn = model.hideExplicit
        eye.setSymbol(model.hideExplicit ? "eye.slash" : "eye")
        return eye
    }

    private var authorBookmarksMoreBtn: ToolButton?
    private func authorBookmarksMoreButton() -> ToolButton {
        let button = authorBookmarksMoreBtn ?? ToolButton(theme: theme, symbol: "arrow.down.circle",
                                                          tooltip: "Load more bookmarks") { [weak self] in
            self?.model.loadMoreAuthorBookmarks()
        }
        authorBookmarksMoreBtn = button
        return button
    }

    // The bookmarks/collections panes are local-first: these buttons are
    // their only network trigger.
    private var authorBookmarksRefreshBtn: ToolButton?
    private func authorBookmarksRefreshButton() -> ToolButton {
        let button = authorBookmarksRefreshBtn ?? ToolButton(theme: theme, symbol: "arrow.clockwise",
                                                             tooltip: "Refresh bookmarks from AO3") { [weak self] in
            self?.model.refreshAuthorBookmarks()
        }
        authorBookmarksRefreshBtn = button
        return button
    }

    private var authorCollectionsRefreshBtn: ToolButton?
    private func authorCollectionsRefreshButton() -> ToolButton {
        let button = authorCollectionsRefreshBtn ?? ToolButton(theme: theme, symbol: "arrow.clockwise",
                                                               tooltip: "Refresh collections from AO3") { [weak self] in
            self?.model.refreshAuthorCollections()
        }
        authorCollectionsRefreshBtn = button
        return button
    }

    private func fandomCloseButton() -> ToolButton {
        let button = fandomCloseBtn ?? ToolButton(theme: theme, symbol: "xmark", tooltip: "Close works list") { [weak self] in
            self?.model.closeFandomWorks()
        }
        fandomCloseBtn = button
        return button
    }

    private func fandomSearchButton() -> ToolButton {
        let button = fandomSearchBtn ?? ToolButton(theme: theme, symbol: "magnifyingglass", tooltip: "Search AO3 for this fandom's works") { [weak self] in
            self?.model.searchFandomOnAO3()
        }
        fandomSearchBtn = button
        return button
    }

    private func fandomLibraryBackButton() -> ToolButton {
        let button = fandomLibraryBackBtn ?? ToolButton(theme: theme, symbol: "arrow.left", tooltip: "Back to library works") { [weak self] in
            self?.model.showFandomLibraryWorks()
        }
        fandomLibraryBackBtn = button
        return button
    }

    /// Drill-in staleness line: "N works stored · refreshed 3d ago" when a
    /// full crawl has ever completed, plain count otherwise.
    private func storedWorksSubtitle(count: Int, crawledAt: String?) -> String {
        let stored = "\(count) works stored"
        guard let crawledAt, !crawledAt.isEmpty else { return stored }
        return "\(stored) · refreshed \(Fmt.relativeTime(crawledAt))"
    }

    /// The drill-in header button: "Refresh Works" idle, "Cancel" while a
    /// crawl runs. render() re-invokes this every pass, so the label always
    /// tracks the current state.
    private func refreshWorksButton(forAuthor: Bool) -> LabelToolButton {
        let button: LabelToolButton
        if forAuthor {
            button = authorRefreshBtn ?? LabelToolButton(theme: theme) { [weak self] in
                guard let model = self?.model else { return }
                model.isLoadingAuthor ? model.cancelAuthorWorksRefresh() : model.refreshAuthorWorks()
            }
            authorRefreshBtn = button
        } else {
            button = subscriptionRefreshBtn ?? LabelToolButton(theme: theme) { [weak self] in
                guard let model = self?.model else { return }
                model.isLoadingSubscriptionWorks ? model.cancelSubscriptionWorksRefresh() : model.refreshSubscriptionWorks()
            }
            subscriptionRefreshBtn = button
        }
        let loading = forAuthor ? model.isLoadingAuthor : model.isLoadingSubscriptionWorks
        button.configure(title: loading ? "Cancel" : "Refresh Works",
                         symbol: loading ? "xmark" : "arrow.clockwise",
                         tooltip: loading
                            ? "Stop fetching — works fetched so far are kept"
                            : "Fetch this author’s complete works list from AO3, page by page")
        return button
    }

    // MARK: - Render

    private func render() {
        // Track the app text-size setting so toolbar fonts refresh with it.
        _ = theme.uiFontScale
        // Request-progress banner: hidden unless a branch below hands it a
        // tracked operation id (only work-detail refresh so far). The defer
        // runs on every early return, so no branch has to remember to hide it.
        var requestOverlayOpID: UInt64?
        defer { setRequestProgressOverlay(requestOverlayOpID) }
        view.layer?.backgroundColor = theme.nsBg.cgColor
        toolbar.applyTheme()
        toolbarTop.constant = model.immersive ? 20 : 0
        privacyDot.layer?.backgroundColor = theme.nsSage.cgColor
        immersiveExit.layer?.backgroundColor = theme.nsSurface.cgColor
        immersiveExit.layer?.borderColor = theme.nsLine.cgColor
        immersiveExit.contentTintColor = theme.nsInk2
        immersiveExit.isHidden = !model.immersive

        // Only the work-detail branch places an after-title view; clearing
        // here keeps the list branches from inheriting the detail pane's
        // Start Reading button.
        toolbar.setAfterTitle([])

        // Subscriptions drill-in: an author subscription's works, without
        // ever leaving the Subscriptions section.
        if model.section == .subscriptions, let title = model.subscriptionWorksTitle, model.selectedWork == nil {
            let isAuthor = model.subscriptionWorksSubType == "author"
            let author = model.subscriptionWorksSubId ?? title
            let sub = model.isLoadingSubscriptionWorks
                ? (model.subscriptionWorksFetchStatus ?? "Fetching works from AO3…")
                : storedWorksSubtitle(count: model.filteredSubscriptionWorks.count,
                                      crawledAt: model.subscriptionWorksCrawledAt)
            toolbar.configure(title: title, sub: sub)
            toolbar.setLeading([subscriptionCloseButton()])
            var trailing: [NSView] = [sortFilterMenu.makeButton(for: .subscriptions),
                                      worksFilterButton(for: .subscriptions),
                                      refreshWorksButton(forAuthor: false)]
            if isAuthor {
                trailing = authorHeaderButtons(username: author) + trailing
            }
            toolbar.setTrailing(trailing)
            show(mode: .subscriptionWorks(title))
            return
        }

        // Authors drill-in: one of the author's lists (works, bookmarks,
        // or collections) in this pane — their profile sits in the list
        // pane, and its buttons pick which list shows here.
        if model.section == .authors, let author = model.authorUsername, model.selectedWork == nil {
            switch model.authorPane {
            case .works:
                let sub = model.isLoadingAuthor
                    ? (model.authorFetchStatus ?? "Fetching works from AO3…")
                    : storedWorksSubtitle(count: model.filteredAuthorWorks.count,
                                          crawledAt: model.authorWorksCrawledAt)
                toolbar.configure(title: "Works", sub: sub)
                toolbar.setLeading([])
                toolbar.setTrailing([sortFilterMenu.makeButton(for: .authors),
                                     worksFilterButton(for: .authors),
                                     refreshWorksButton(forAuthor: true)])
                show(mode: .subscriptionWorks(author))
            case .bookmarks:
                let count = model.authorBookmarksList.count
                let sub = model.isLoadingAuthorBookmarks
                    ? "Fetching bookmarks from AO3…"
                    : count == 1 ? "1 bookmark" : "\(count) bookmarks"
                toolbar.configure(title: "Bookmarks", sub: sub)
                toolbar.setLeading([])
                var trailing: [NSView] = []
                if model.authorBookmarksHasNext {
                    trailing.append(authorBookmarksMoreButton())
                }
                trailing.append(authorBookmarksRefreshButton())
                toolbar.setTrailing(trailing)
                show(mode: .subscriptionWorks(author))
            case .collections:
                let count = model.authorCollections.count
                let sub = model.isLoadingAuthorCollections
                    ? "Fetching collections from AO3…"
                    : count == 1 ? "1 collection" : "\(count) collections"
                toolbar.configure(title: "Collections", sub: sub)
                toolbar.setLeading([])
                toolbar.setTrailing([authorCollectionsRefreshButton()])
                show(mode: .authorCollections(author))
            }
            return
        }

        // Fandoms drill-in, without leaving the Fandoms section. Local-first:
        // the library's works for the fandom, with an explicit Search AO3
        // action that swaps the pane to the archive's paged tag results.
        if model.section == .fandoms, let tag = model.fandomWorksTag, model.selectedWork == nil {
            let tagAO3 = ao3Button(url: ExternalLinkOpener.ao3TagURL(tag),
                                   tooltip: "Open this tag's works on AO3 in your browser")
            if model.fandomSearchActive {
                let search = model.search
                toolbar.configure(title: tag, sub: search.resultsSubtitle)
                toolbar.setLeading([fandomLibraryBackButton()])
                toolbar.setTrailing([tagAO3] + (search.hasSearched
                    ? [makePagerHost(), worksFilterButton(for: .search)] : []))
            } else {
                let count = model.fandomLibraryWorks.count
                toolbar.configure(title: tag,
                                  sub: count == 1 ? "1 work in library" : "\(count) works in library")
                toolbar.setLeading([fandomCloseButton()])
                toolbar.setTrailing([tagAO3, fandomSearchButton(), worksFilterButton(for: .fandoms)])
            }
            show(mode: .searchResults)
            return
        }

        // Reading Lists drill-in: the selected list's works, mirroring the
        // Subscriptions → works flow.
        if model.section == .readingLists, let listID = model.selectedReadingListID,
           model.selectedWork == nil {
            let name = appState.readingLists.first { $0.id == listID }?.name ?? "Reading List"
            let summary = appState.readingListSummary(listID)
            let sub = summary.totalCount == 0
                ? "Reading list"
                : "\(Fmt.k(summary.totalWords)) words · \(summary.readCount) of \(summary.totalCount) read"
            toolbar.configure(title: name, sub: sub)
            toolbar.setLeading([readingListCloseButton()])
            toolbar.setTrailing([sortFilterMenu.makeButton(for: .readingLists),
                                 worksFilterButton(for: .readingLists)])
            show(mode: .searchResults)
            return
        }

        // Settings spans this pane full-width (the list pane is collapsed),
        // hosting the same SwiftUI panes the standalone window used to.
        if model.section == .settings {
            toolbar.configure(title: "Settings", sub: nil)
            toolbar.setLeading([])
            toolbar.setTrailing([])
            show(mode: .settings)
            return
        }

        // Search section with no selection: the list pane is collapsed, so
        // this pane holds the whole flow — scope tabs in place of the title,
        // the scope's form, flipping to results once a query runs (back
        // button returns). Works/Bookmarks results use the works table;
        // Tags/Users/Collections render their own hit lists.
        if model.section == .search, model.selectedWork == nil {
            let search = model.search
            if search.showingResults, let collectionName = search.splitCollectionName {
                // Split collection view: the pane toolbar names the
                // collection; the back arrow and both pagers live in the
                // halves' own header bars.
                toolbar.configure(title: search.splitCollectionTitle ?? "Collection",
                                  sub: splitCollectionSubtitle(search))
                toolbar.setLeading([])
                toolbar.setTrailing([ao3Button(url: ExternalLinkOpener.ao3CollectionURL(collectionName),
                                               tooltip: "Open this collection on AO3 in your browser"),
                                     searchSourceButton()])
                show(mode: .collectionSplit)
                return
            }
            if search.showingResults {
                let worksStyle = search.scope == .works
                toolbar.configure(title: "", sub: scopeResultsSubtitle(search))
                let back = searchFormBackButton()
                // The same arrow pops one level: to the collections hit
                // list behind a drill-in, to the form otherwise.
                back.toolTip = search.canReturnToCollectionHits
                    ? "Back to collections results" : "Back to search criteria"
                toolbar.setLeading([back])
                if worksStyle {
                    var trailing: [NSView] = search.hasSearched
                        ? [makePagerHost(), worksFilterButton(for: .search)] : []
                    // Server-side sort — only form queries carry AO3 sort params.
                    if search.hasSearched, case .form = search.activeQuery,
                       searchSortField() != nil {
                        trailing.insert(searchSortButton(), at: 0)
                    }
                    trailing.append(searchSourceButton())
                    toolbar.setTrailing(trailing)
                    show(mode: .searchResults)
                } else {
                    // AO3 collections and bookmark results are paged like
                    // works results.
                    var trailing: [NSView] = []
                    switch search.activeQuery {
                    case .collectionsIndex, .bookmarkSearch:
                        trailing.append(makePagerHost())
                    default:
                        break
                    }
                    if search.scope == .bookmarks, search.hasSearched {
                        trailing.append(bookmarksFilterButton())
                    }
                    trailing.append(searchSourceButton())
                    toolbar.setTrailing(trailing)
                    show(mode: .scopeResults)
                }
            } else {
                // The scope tabs live where the title would be — only while
                // the form is showing; results keep a plain header.
                let tabs = scopeTabsView()
                tabs.configure(selected: search.scope)
                toolbar.setAfterTitle([tabs])
                toolbar.configure(title: "", sub: nil)
                toolbar.setLeading([])
                if search.scope == .works {
                    toolbar.setTrailing([searchGoButton(), reloadCriteriaButton(),
                                         searchEyeButton(), searchSourceButton()])
                    show(mode: .searchForm)
                } else {
                    toolbar.setTrailing([searchGoButton(), searchSourceButton()])
                    show(mode: .scopeForm)
                }
            }
            return
        }

        if model.section == .inbox, let item = appState.selectedInboxItem {
            toolbar.configure(title: item.workReference, sub: "Comment by \(item.author)")
            toolbar.setLeading([])
            toolbar.setTrailing([])
            let mode = Mode.inboxThread(item.commentId)
            show(mode: mode)
            if case .inboxThread = renderedMode, let host = detailHost {
                host.rootView = AnyView(InboxThreadView(theme: theme, appState: appState))
            }
            return
        }

        guard let work = model.selectedWork else {
            toolbar.configure(title: "", sub: nil)
            toolbar.setLeading([])
            toolbar.setTrailing([])
            show(mode: .empty)
            return
        }

        let reading = model.readerOpen
        let cameFromResults = model.section == .search
            || (model.section == .subscriptions && model.subscriptionWorksTitle != nil)
            || (model.section == .authors && model.authorUsername != nil)
            || (model.section == .fandoms && model.fandomWorksTag != nil)
        toolbar.configure(title: reading ? work.title : "Details",
                          sub: !reading && appState.isRefreshingWork ? "Refreshing from AO3…" : nil)
        if !reading { requestOverlayOpID = appState.workRefreshOpID }
        toolbar.setLeading(reading ? [backButton] : (cameFromResults ? [resultsBackButton] : []))
        immersiveButton.isOn = model.immersive
        let bookmarked = appState.bookmarkedWorkIDs.contains(work.id)
        bookmarkButton.setSymbol(bookmarked ? "bookmark.fill" : "bookmark")
        bookmarkButton.tintOverride = bookmarked ? theme.nsAccent : nil
        if reading {
            toolbar.setTrailing([settingsButton, immersiveButton, chaptersButton,
                                 readerRefreshButton(), commentsButton, bookmarkButton])
        } else {
            refreshDetailActionButtons(for: work, bookmarked: bookmarked)
            toolbar.setAfterTitle([startReadingButton])
            var trailing: [NSView] = [ao3Button(url: ExternalLinkOpener.ao3WorkURL(work.id),
                                                tooltip: "Open this work on AO3 in your browser"),
                                      settingsButton, detailRefreshButton(),
                                      downloadButton, readingListButton, subscribeButton,
                                      kudosButton, workCommentsButton]
            if bookmarked { trailing.append(editBookmarkButton) }
            trailing.append(bookmarkButton)
            toolbar.setTrailing(trailing)
        }

        show(mode: reading ? .reading(work.id, model.readerChapter) : .detail(work.id))

        // Detail is SwiftUI and re-renders itself; only rebuild on identity change.
        if case .detail = renderedMode, let host = detailHost {
            host.rootView = AnyView(DetailView(theme: theme, appState: appState, model: model, work: work))
        }
    }

    private func show(mode: Mode) {
        guard mode != renderedMode else { return }

        // The split collection view only appears in its own mode; every
        // other mode clears it here rather than case by case.
        if mode != .collectionSplit {
            collectionSplitController?.view.removeFromSuperview()
        }

        switch mode {
        case .collectionSplit:
            readerController.view.removeFromSuperview()
            resultsController?.view.removeFromSuperview()
            detailHost?.removeFromSuperview()
            detailHost = nil
            emptyHost?.removeFromSuperview()
            pin(collectionSplit().view)
        case .searchResults, .subscriptionWorks:
            readerController.view.removeFromSuperview()
            detailHost?.removeFromSuperview()
            detailHost = nil
            emptyHost?.removeFromSuperview()
            if resultsController == nil {
                let controller = SearchResultsViewController(theme: theme, appState: appState, model: model)
                addChild(controller)
                resultsController = controller
            }
            pin(resultsController!.view)

        case .searchForm:
            readerController.view.removeFromSuperview()
            resultsController?.view.removeFromSuperview()
            emptyHost?.removeFromSuperview()
            let host = detailHost ?? NSHostingView(rootView: AnyView(EmptyView()))
            host.rootView = AnyView(SearchFormView(theme: theme, appState: appState, model: model))
            detailHost = host
            pin(host)

        case .settings:
            readerController.view.removeFromSuperview()
            resultsController?.view.removeFromSuperview()
            emptyHost?.removeFromSuperview()
            let host = detailHost ?? NSHostingView(rootView: AnyView(EmptyView()))
            host.rootView = AnyView(SettingsRootView(theme: theme, appState: appState, model: model))
            detailHost = host
            pin(host)

        case .scopeForm:
            readerController.view.removeFromSuperview()
            resultsController?.view.removeFromSuperview()
            emptyHost?.removeFromSuperview()
            let host = detailHost ?? NSHostingView(rootView: AnyView(EmptyView()))
            host.rootView = AnyView(ScopeSearchFormView(theme: theme, appState: appState, model: model))
            detailHost = host
            pin(host)

        case .scopeResults:
            readerController.view.removeFromSuperview()
            resultsController?.view.removeFromSuperview()
            emptyHost?.removeFromSuperview()
            let host = detailHost ?? NSHostingView(rootView: AnyView(EmptyView()))
            host.rootView = AnyView(ScopeResultsView(theme: theme, appState: appState, model: model))
            detailHost = host
            pin(host)

        case .authorCollections:
            readerController.view.removeFromSuperview()
            resultsController?.view.removeFromSuperview()
            emptyHost?.removeFromSuperview()
            let host = detailHost ?? NSHostingView(rootView: AnyView(EmptyView()))
            host.rootView = AnyView(AuthorCollectionsView(theme: theme, appState: appState, model: model))
            detailHost = host
            pin(host)

        case .empty:
            readerController.view.removeFromSuperview()
            resultsController?.view.removeFromSuperview()
            detailHost?.removeFromSuperview()
            detailHost = nil
            if emptyHost == nil {
                let host = NSHostingView(rootView: AnyView(
                    EmptyStateMac(theme: theme, icon: "book",
                                  title: "Select a work to begin",
                                  message: "Choose something from the list, or browse the archive. Everything you read stays private.")))
                emptyHost = host
            }
            pin(emptyHost!)

        case .detail(let workID):
            readerController.view.removeFromSuperview()
            resultsController?.view.removeFromSuperview()
            emptyHost?.removeFromSuperview()
            if let work = appState.work(byID: workID) {
                let host = detailHost ?? NSHostingView(rootView: AnyView(EmptyView()))
                host.rootView = AnyView(DetailView(theme: theme, appState: appState, model: model, work: work))
                detailHost = host
                pin(host)
            }

        case .reading(let workID, let chapter):
            detailHost?.removeFromSuperview()
            detailHost = nil
            resultsController?.view.removeFromSuperview()
            emptyHost?.removeFromSuperview()
            if let work = appState.work(byID: workID) {
                pin(readerController.view)
                readerController.show(work: work, chapterIndex: chapter)
            }

        case .inboxThread:
            readerController.view.removeFromSuperview()
            resultsController?.view.removeFromSuperview()
            emptyHost?.removeFromSuperview()
            let host = detailHost ?? NSHostingView(rootView: AnyView(EmptyView()))
            host.rootView = AnyView(InboxThreadView(theme: theme, appState: appState))
            detailHost = host
            pin(host)
        }
        renderedMode = mode
    }

    /// The split collection view: works half (back arrow + its own pager)
    /// and bookmarked-items half (its own pager), independently paged,
    /// divided by a draggable thin divider.
    private func collectionSplit() -> NSSplitViewController {
        if let collectionSplitController { return collectionSplitController }
        let split = NSSplitViewController()
        split.splitView.dividerStyle = .thin
        let worksItem = NSSplitViewItem(viewController: splitHalf(isWorks: true))
        worksItem.minimumThickness = 320
        split.addSplitViewItem(worksItem)
        let bookmarksItem = NSSplitViewItem(viewController: splitHalf(isWorks: false))
        bookmarksItem.minimumThickness = 320
        split.addSplitViewItem(bookmarksItem)
        addChild(split)
        collectionSplitController = split
        return split
    }

    /// One half of the split: a compact header bar over a works table.
    private func splitHalf(isWorks: Bool) -> NSViewController {
        let controller = NSViewController()
        let root = NSView()
        root.wantsLayer = true
        controller.view = root

        let header = NSHostingView(rootView: CollectionSplitPaneHeader(
            theme: theme, appState: appState, model: model, isWorks: isWorks))
        header.translatesAutoresizingMaskIntoConstraints = false
        let results = SearchResultsViewController(
            theme: theme, appState: appState, model: model,
            fixedContext: isWorks ? .search : .collectionBookmarks)
        controller.addChild(results)
        let table = results.view
        table.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(header)
        root.addSubview(table)
        NSLayoutConstraint.activate([
            header.topAnchor.constraint(equalTo: root.topAnchor),
            header.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            header.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            table.topAnchor.constraint(equalTo: header.bottomAnchor),
            table.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            table.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            table.bottomAnchor.constraint(equalTo: root.bottomAnchor),
        ])
        return controller
    }

    private func pin(_ subview: NSView) {
        guard subview.superview != container else { return }
        subview.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(subview)
        NSLayoutConstraint.activate([
            subview.topAnchor.constraint(equalTo: container.topAnchor),
            subview.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            subview.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            subview.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])
    }

    /// Symbols, tints, and enabled states for the detail-mode work action
    /// buttons — re-run on every render, like the bookmark button.
    private func refreshDetailActionButtons(for work: Work, bookmarked: Bool) {
        let started = model.progress(for: work) > 0
        let currentChapter = appState.progressMap[work.id]?.chapter ?? 1
        startReadingButton.isOn = true
        startReadingButton.toolTip = started
            ? "Continue reading · Chapter \(currentChapter)" : "Start reading"

        let downloaded = appState.downloadedWorkIDs.contains(work.id)
        downloadButton.setSymbol(appState.isDownloading(work.id) ? "arrow.down.circle.dotted"
                                 : downloaded ? "checkmark.circle" : "arrow.down.circle")
        downloadButton.tintOverride = downloaded ? theme.nsSage : nil
        downloadButton.toolTip = downloaded ? "Downloaded" : "Download for offline"

        let workId = UInt64(work.id)
        let inList = workId.map { id in
            appState.readingLists.contains { appState.bridge.getReadingListItems($0.id).contains(id) }
        } ?? false
        readingListButton.setSymbol(inList ? "books.vertical.fill" : "books.vertical")
        readingListButton.tintOverride = inList ? theme.nsAccent : nil
        readingListButton.isEnabled = workId != nil

        let subscribed = appState.isSubscribedToWork(work.id)
        subscribeButton.setSymbol(subscribed ? "bell.fill" : "bell")
        subscribeButton.tintOverride = subscribed ? theme.nsAccent : nil
        subscribeButton.isEnabled = appState.ao3Username != nil
            && !appState.subscriptionTogglingWorkIDs.contains(work.id)
        subscribeButton.toolTip = appState.ao3Username == nil
            ? "Sign in to subscribe to this work"
            : subscribed ? "Unsubscribe from this work on AO3" : "Subscribe to this work on AO3"

        // Heart states: empty = no kudos (or the POST failed), faded red =
        // request in flight, full red = AO3 confirmed.
        let hasKudos = appState.kudosGivenWorkIDs.contains(work.id)
        let kudosPending = appState.kudosPendingWorkIDs.contains(work.id)
        let kudosRed = NSColor(Color(hex: "CE514D"))
        kudosButton.setSymbol(hasKudos || kudosPending ? "heart.fill" : "heart")
        kudosButton.tintOverride = hasKudos ? kudosRed
            : kudosPending ? kudosRed.withAlphaComponent(0.45) : nil
        kudosButton.isEnabled = !hasKudos && !kudosPending
        kudosButton.toolTip = hasKudos ? "Kudos left — kudos are permanent on AO3"
            : kudosPending ? "Leaving kudos…" : "Leave kudos on AO3"

        workCommentsButton.toolTip = work.comments > 0
            ? "Comments · \(Fmt.k(work.comments))" : "Comments"
    }

    // MARK: - Actions

    /// Reading settings as a window sheet — a popover this wide would hang
    /// outside the window's visual bounds when anchored to the toolbar.
    private func toggleSettingsPopover() {
        guard presentedViewControllers?.isEmpty != false else { return }
        var dismissRef: () -> Void = {}
        let view = ReadingSettingsView(theme: theme, onClose: { dismissRef() })
        let hosting = NSHostingController(rootView: view)
        dismissRef = { [weak self, weak hosting] in
            if let hosting { self?.dismiss(hosting) }
        }
        presentAsSheet(hosting)
    }

    @objc private func exitImmersive() {
        model.immersive = false
    }

    private func toggleChaptersPopover() {
        if let popover = chaptersPopover, popover.isShown {
            popover.close()
            chaptersPopover = nil
            return
        }
        guard let work = model.selectedWork else { return }
        let popover = NSPopover()
        popover.behavior = .transient
        popover.contentViewController = NSHostingController(
            rootView: ChapterListPopover(theme: theme, appState: appState, model: model,
                                         workID: work.id,
                                         onSelect: { [weak self] in
                                             self?.chaptersPopover?.close()
                                             self?.chaptersPopover = nil
                                         }))
        popover.show(relativeTo: chaptersButton.bounds, of: chaptersButton, preferredEdge: .maxY)
        chaptersPopover = popover
    }

    private func toggleReadingListPopover() {
        if let popover = readingListPopover, popover.isShown {
            popover.close()
            readingListPopover = nil
            return
        }
        guard let work = model.selectedWork else { return }
        let popover = NSPopover()
        popover.behavior = .transient
        popover.contentViewController = NSHostingController(
            rootView: ReadingListPopover(theme: theme, appState: appState, work: work))
        popover.show(relativeTo: readingListButton.bounds, of: readingListButton, preferredEdge: .maxY)
        readingListPopover = popover
    }

    /// Comments for the whole work (detail-mode toolbar), as a sheet.
    private func showWorkComments() {
        guard let work = model.selectedWork else { return }
        var dismissRef: () -> Void = {}
        let view = MacCommentsView(theme: theme, appState: appState,
                                   workID: work.id,
                                   chapterID: nil,
                                   title: work.title,
                                   subtitle: nil,
                                   onClose: { dismissRef() })
        let hosting = NSHostingController(rootView: view)
        dismissRef = { [weak self, weak hosting] in
            if let hosting { self?.dismiss(hosting) }
        }
        presentAsSheet(hosting)
    }

    private func showBookmarkEditSheet() {
        guard let work = model.selectedWork else { return }
        var dismissRef: () -> Void = {}
        let view = MacBookmarkEditView(theme: theme, appState: appState,
                                       workID: work.id,
                                       workTitle: work.title,
                                       onClose: { dismissRef() })
        let hosting = NSHostingController(rootView: view)
        dismissRef = { [weak self, weak hosting] in
            if let hosting { self?.dismiss(hosting) }
        }
        presentAsSheet(hosting)
    }

    /// Comments for the chapter currently open in the reader, as a sheet.
    private func showChapterComments() {
        guard let work = model.selectedWork else { return }
        let chapterIndex = model.readerChapter
        var chapterId: UInt64?
        if let chapters = appState.chaptersForWork(work.id), chapterIndex < chapters.count {
            let id = chapters[chapterIndex].chapterId
            chapterId = id > 0 ? UInt64(id) : nil
        }
        var dismissRef: () -> Void = {}
        let view = MacCommentsView(theme: theme, appState: appState,
                                   workID: work.id,
                                   chapterID: chapterId,
                                   title: work.title,
                                   subtitle: "Chapter \(chapterIndex + 1)",
                                   onClose: { dismissRef() })
        let hosting = NSHostingController(rootView: view)
        dismissRef = { [weak self, weak hosting] in
            if let hosting { self?.dismiss(hosting) }
        }
        presentAsSheet(hosting)
    }
}


/// Chapter list for the reader toolbar — jump anywhere in the work.
struct ChapterListPopover: View {
    @Bindable var theme: AppTheme
    @Bindable var appState: AppState
    @Bindable var model: MacAppModel
    let workID: String
    let onSelect: () -> Void

    var body: some View {
        let chapters = appState.chaptersForWork(workID) ?? []
        ScrollViewReader { proxy in
            ScrollView {
                VStack(spacing: 0) {
                    ForEach(Array(chapters.enumerated()), id: \.offset) { index, chapter in
                        chapterRow(index: index, chapter: chapter)
                            .id(index)
                    }
                    if chapters.isEmpty {
                        Text("Chapters are still loading…")
                            .font(Font(MacFont.ui(12.5)))
                            .foregroundStyle(theme.ink3)
                            .padding(16)
                    }
                }
                .padding(.vertical, 6)
            }
            .onAppear { proxy.scrollTo(model.readerChapter, anchor: .center) }
        }
        .frame(width: 300, height: 360)
        .background(theme.surface)
    }

    private func chapterRow(index: Int, chapter: UChapter) -> some View {
        let current = index == model.readerChapter
        let title = chapter.title.isEmpty ? "Chapter \(index + 1)" : chapter.title
        return Button {
            model.openReader(workID, chapter: index)
            onSelect()
        } label: {
            HStack(spacing: 10) {
                Text("\(index + 1)")
                    .font(Font(MacFont.ui(11, weight: .bold)))
                    .foregroundStyle(current ? theme.onAccent : theme.ink3)
                    .frame(minWidth: 22, minHeight: 22)
                    .background(current ? theme.accent : theme.surface2)
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                Text(title)
                    .font(Font(MacFont.ui(12.5, weight: current ? .semibold : .regular)))
                    .foregroundStyle(current ? theme.ink : theme.ink2)
                    .lineLimit(1)
                Spacer()
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
