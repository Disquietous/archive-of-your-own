import AppKit
import SwiftUI

extension ReadPaneViewController {
    // MARK: - Header buttons

    /// Same filter-popover machinery as ListPaneViewController: a cached
    /// toggle button anchoring a transient popover, sized to its SwiftUI
    /// content before showing.
    func filterButton(key: String, active: Bool, content: @escaping () -> AnyView) -> ToolButton {
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
    func bookmarksFilterButton() -> ToolButton {
        let button = filterButton(key: "bookmark-search",
                                  active: model.search.bookmarkListFilter.isActive) { [theme, model] in
            AnyView(BookmarkListFilterView(theme: theme, model: model))
        }
        // A client-side sieve over the fetched rows — make sure it can't be
        // mistaken for a server-side search refinement.
        button.toolTip = "Filter the fetched results (this page only)"
        return button
    }

    func worksFilterButton(for section: MacAppModel.Section) -> ToolButton {
        let button = filterButton(key: "works-\(section)",
                                  active: model.lists.workListFilter(for: section).isActive) { [theme, model] in
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
    func searchSortField() -> UFormField? {
        model.search.formFields.first { $0.name.hasSuffix("[sort_column]") }
    }

    /// Server-side sort menu for search results: options come from the
    /// scraped form's sort fields; picking one rewrites the criteria and
    /// re-runs the query, so re-sorting no longer means a round-trip back
    /// to the form.
    func searchSortButton() -> ToolButton {
        var anchor: ToolButton!
        let button = ToolButton(theme: theme, symbol: "arrow.up.arrow.down",
                                tooltip: "Sort results (re-runs the search)") { [weak self] in
            guard let self, let anchor else { return }
            showSearchSortMenu(from: anchor)
        }
        anchor = button
        return button
    }

    /// A source's sort options (its adapter's declaration), for the sort
    /// menu over source results.
    func sourceSortSpec() -> SortSpec? {
        guard model.search.activeSourceQuery != nil else { return nil }
        return appState.bridge.searchSchema(source: model.search.sourceTab, languageCandidates: [])?.sort
    }

    func showSourceSortMenu(from anchor: NSView, spec: SortSpec) {
        let search = model.search
        let menu = NSMenu()
        menu.autoenablesItems = false
        let sortHeader = NSMenuItem(title: "Sort By", action: nil, keyEquivalent: "")
        sortHeader.isEnabled = false
        menu.addItem(sortHeader)
        let currentSort = search.activeSourceQuery?.sortColumn ?? spec.defaultColumn
        for option in spec.columns {
            let item = NSMenuItem(title: option.label, action: #selector(sourceSortChosen(_:)), keyEquivalent: "")
            item.target = self
            item.state = option.value == currentSort ? .on : .off
            item.representedObject = ["column", option.value]
            menu.addItem(item)
        }
        menu.addItem(.separator())
        let directionHeader = NSMenuItem(title: "Direction", action: nil, keyEquivalent: "")
        directionHeader.isEnabled = false
        menu.addItem(directionHeader)
        let currentDirection = search.activeSourceQuery?.sortDirection ?? spec.defaultDirection
        for option in spec.directions {
            let item = NSMenuItem(title: option.label, action: #selector(sourceSortChosen(_:)), keyEquivalent: "")
            item.target = self
            item.state = option.value == currentDirection ? .on : .off
            item.representedObject = ["direction", option.value]
            menu.addItem(item)
        }
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: anchor.bounds.height + 4), in: anchor)
    }

    @objc func sourceSortChosen(_ sender: NSMenuItem) {
        guard let pair = sender.representedObject as? [String], pair.count == 2 else { return }
        model.search.resortSourceResults(column: pair[0] == "column" ? pair[1] : nil,
                                         direction: pair[0] == "direction" ? pair[1] : nil,
                                         appState: appState)
    }

    func showSearchSortMenu(from anchor: NSView) {
        if case .source = model.search.activeQuery, let spec = sourceSortSpec() {
            showSourceSortMenu(from: anchor, spec: spec)
            return
        }
        guard let sortField = searchSortField() else { return }
        let search = model.search
        let menu = NSMenu()
        menu.autoenablesItems = false

        let sortHeader = NSMenuItem(title: "Sort By", action: nil, keyEquivalent: "")
        sortHeader.isEnabled = false
        menu.addItem(sortHeader)
        // AO3 pre-selects a default when the field is unset in the
        // request behind the current results.
        let currentSort = search.activeWorksRequest?.fieldValues[sortField.name]
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
            let currentDirection = search.activeWorksRequest?.fieldValues[directionField.name]
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

    @objc func searchSortChosen(_ sender: NSMenuItem) {
        guard let pair = sender.representedObject as? [String], pair.count == 2 else { return }
        // Amend the request behind the current results — never the form,
        // which programmatic triggers (tag clicks) don't populate.
        model.search.updateWorksSearchField(pair[0], value: pair[1], appState: appState)
    }

    /// The pager, hosted for the toolbar. The toolbar sits in the window's
    /// titlebar band (fullSizeContentView), and an NSHostingView there
    /// inherits a top safe-area inset that shoves the SwiftUI content below
    /// the bar's midline — the same mechanism the Tor overlay hit. Clearing
    /// safeAreaRegions makes it center like the AppKit ToolButtons.
    func makePagerHost() -> NSHostingView<SearchPagerView> {
        if let pagerHost { return pagerHost }
        let host = NSHostingView(rootView: SearchPagerView(theme: theme, appState: appState, model: model))
        host.safeAreaRegions = []
        pagerHost = host
        return host
    }

    /// The header's "Ao3" pill: opens the shown entity's archive page in
    /// the user's configured link app. One cached instance — only one of
    /// the entity headers (work, collection, tag) is ever visible, and the
    /// URL is re-set on every render pass.
    /// Open-on-site: the stored canonical URL, captioned with the source's
    /// short name. Callers hide it when the row has no URL.
    func siteButton(url: URL?, caption: String, tooltip: String) -> LabelToolButton {
        let button = siteBtn ?? LabelToolButton(theme: theme) { [weak self] in
            guard let self, let url = siteURL else { return }
            ExternalLinkOpener.open(url, bridge: appState.bridge)
        }
        siteBtn = button
        siteURL = url
        button.configure(title: caption, symbol: "arrow.up.right", tooltip: tooltip)
        button.isEnabled = url != nil
        return button
    }

    func readerRefreshButton(label: String = "Refresh") -> ToolButton {
        let button = readerRefreshBtn ?? ToolButton(theme: theme, symbol: "arrow.clockwise",
                                                    tooltip: "Refresh chapter from AO3") { [weak self] in
            self?.readerController.refreshChaptersFromAO3()
        }
        readerRefreshBtn = button
        return button
    }

    /// Detail header: re-fetch the work's current details from AO3.
    /// The fetch is dispatched by the row's source in the core; only the
    /// label names the site.
    func detailRefreshButton(label: String = "Refresh") -> ToolButton {
        let button = detailRefreshBtn ?? ToolButton(theme: theme, symbol: "arrow.clockwise",
                                                    tooltip: label) { [weak self] in
            guard let self, let id = model.selectedWorkID else { return }
            Task { @MainActor in await self.appState.refreshWorkMetadata(id) }
        }
        detailRefreshBtn = button
        button.toolTip = label
        return button
    }

    /// Inbox thread header: fetch the thread from AO3 again. Threads are
    /// cached forever once fetched, so this is the only way to pick up
    /// replies posted since.
    func inboxThreadRefreshButton() -> ToolButton {
        let button = inboxThreadRefreshBtn ?? ToolButton(theme: theme, symbol: "arrow.clockwise",
                                                         tooltip: "Refresh thread from AO3") { [weak self] in
            guard let self else { return }
            Task { @MainActor in await self.appState.refreshInboxThread() }
        }
        inboxThreadRefreshBtn = button
        return button
    }

    func subscriptionCloseButton() -> ToolButton {
        let button = subscriptionCloseBtn ?? ToolButton(theme: theme, symbol: "xmark", tooltip: "Close works list") { [weak self] in
            self?.model.closeSubscriptionWorks()
        }
        subscriptionCloseBtn = button
        return button
    }

    /// Work-detail header (plain-list origin, no results to go back to):
    /// unload the work and return to the empty pane. The list that
    /// selected it may have emptied since, so this is the only way out
    /// besides Escape.
    func detailCloseButton() -> ToolButton {
        let button = detailCloseBtn ?? ToolButton(theme: theme, symbol: "xmark", tooltip: "Close") { [weak self] in
            self?.model.closeSelectedWork()
        }
        detailCloseBtn = button
        return button
    }

    /// Inbox thread header: deselect the message and return to the empty pane.
    func inboxThreadCloseButton() -> ToolButton {
        let button = inboxThreadCloseBtn ?? ToolButton(theme: theme, symbol: "xmark", tooltip: "Close") { [weak self] in
            self?.appState.clearInboxSelection()
        }
        inboxThreadCloseBtn = button
        return button
    }

    func readingListCloseButton() -> ToolButton {
        let button = readingListCloseBtn ?? ToolButton(theme: theme, symbol: "xmark", tooltip: "Close list") { [weak self] in
            self?.model.closeReadingList()
        }
        readingListCloseBtn = button
        return button
    }

    /// The author drill-ins' follow bell: the Followed / Subscribed menu
    /// (any AO3 change is confirmed by a sheet first). Glyph and tint track
    /// the live follow state each render.
    func authorSubscribeButton(username: String) -> ToolButton {
        let button = authorSubscribeBtn ?? ToolButton(theme: theme, symbol: "bell",
                                                      tooltip: "Follow") { [weak self] in
            guard let self, let user = drillInAuthorUsername, let anchor = authorSubscribeBtn,
                  let target = model.follows.ao3AuthorTarget(user, ensure: true) else { return }
            FollowBellMenu.show(for: target, follows: model.follows, from: anchor)
        }
        authorSubscribeBtn = button
        let target = model.follows.ao3AuthorTarget(username, ensure: false)
        let shaded = target.map { model.follows.isShaded($0) } ?? false
        button.setSymbol(shaded ? "bell.fill" : "bell")
        button.tintOverride = shaded ? theme.nsAccent : nil
        button.toolTip = "Followed / Subscribed — choose how to track \(username)"
        button.isEnabled = !(target.map { model.follows.isBusy($0) } ?? false)
        return button
    }

    /// Person button for the subscriptions drill-in: opens the two-pane
    /// author view (profile in the list pane, their lists here).
    func authorProfileButton() -> ToolButton {
        let button = authorProfileBtn ?? ToolButton(theme: theme, symbol: "person.crop.circle",
                                                    tooltip: "Show author profile") { [weak self] in
            guard let self, let user = drillInAuthorUsername else { return }
            model.openAuthorProfile(user)
        }
        authorProfileBtn = button
        return button
    }

    /// The follow-bell/profile buttons for an author drill-in header, in
    /// trailing-order. The bell's Subscribed item needs a signed-in AO3
    /// session (the menu disables it otherwise); the profile card is public.
    func authorHeaderButtons(username: String) -> [NSView] {
        drillInAuthorUsername = username
        return [authorSubscribeButton(username: username), authorProfileButton()]
    }
}
