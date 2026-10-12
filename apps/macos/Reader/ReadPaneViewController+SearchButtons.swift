import AppKit
import SwiftUI

extension ReadPaneViewController {
    // MARK: - Search pane buttons (the list pane is collapsed in Search,
    // so the form's actions live in this pane's header)

    /// The search scope tabs living where the "Search" title used to be.
    /// One instance for the pane's lifetime; render() re-reads the model's
    /// scope into it every pass (observable input, per the relay rule).
    func scopeTabsView() -> ScopeTabsView {
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
    func searchSourceButton() -> ToolButton {
        let button = searchSourceBtn ?? ToolButton(theme: theme, symbol: "internaldrive",
                                                   tooltip: "Search source") { [weak self] in
            guard let self else { return }
            model.search.toggleSearchSource(appState)
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
    func splitCollectionSubtitle(_ search: SearchModel) -> String? {
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
    func scopeResultsSubtitle(_ search: SearchModel) -> String? {
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

    func searchFormBackButton() -> ToolButton {
        let button = searchBackBtn ?? ToolButton(theme: theme, symbol: "arrow.left",
                                                 tooltip: "Back to search criteria") { [weak self] in
            self?.model.searchBack()
        }
        searchBackBtn = button
        return button
    }

    func searchGoButton() -> ToolButton {
        let button = searchGoBtn ?? ToolButton(theme: theme, symbol: "magnifyingglass",
                                               tooltip: "Search") { [weak self] in
            guard let self else { return }
            model.search.performScopedSearch(appState)
        }
        searchGoBtn = button
        button.isOn = true
        return button
    }

    func reloadCriteriaButton() -> ToolButton {
        let button = reloadCriteriaBtn ?? ToolButton(theme: theme, symbol: "arrow.clockwise",
                                                     tooltip: "Reload search criteria from AO3") { [weak self] in
            guard let self else { return }
            Task { await self.model.search.scrapeForm(self.appState) }
        }
        reloadCriteriaBtn = button
        return button
    }

    func searchEyeButton() -> ToolButton {
        let eye = searchEyeBtn ?? ToolButton(theme: theme, symbol: "eye",
                                             tooltip: "Hide explicit") { [weak self] in
            self?.model.hideExplicit.toggle()
        }
        searchEyeBtn = eye
        eye.isOn = model.hideExplicit
        eye.setSymbol(model.hideExplicit ? "eye.slash" : "eye")
        return eye
    }

    func authorBookmarksMoreButton() -> ToolButton {
        let button = authorBookmarksMoreBtn ?? ToolButton(theme: theme, symbol: "arrow.down.circle",
                                                          tooltip: "Load more bookmarks") { [weak self] in
            self?.model.author.loadMoreBookmarks()
        }
        authorBookmarksMoreBtn = button
        return button
    }

    func authorBookmarksRefreshButton() -> ToolButton {
        let button = authorBookmarksRefreshBtn ?? ToolButton(theme: theme, symbol: "arrow.clockwise",
                                                             tooltip: "Refresh bookmarks from AO3") { [weak self] in
            self?.model.author.refreshBookmarks()
        }
        authorBookmarksRefreshBtn = button
        return button
    }

    func authorCollectionsRefreshButton() -> ToolButton {
        let button = authorCollectionsRefreshBtn ?? ToolButton(theme: theme, symbol: "arrow.clockwise",
                                                               tooltip: "Refresh collections from AO3") { [weak self] in
            self?.model.author.refreshCollections()
        }
        authorCollectionsRefreshBtn = button
        return button
    }

    func fandomCloseButton() -> ToolButton {
        let button = fandomCloseBtn ?? ToolButton(theme: theme, symbol: "xmark", tooltip: "Close works list") { [weak self] in
            self?.model.closeFandomWorks()
        }
        fandomCloseBtn = button
        return button
    }

    func fandomSearchButton() -> ToolButton {
        let button = fandomSearchBtn ?? ToolButton(theme: theme, symbol: "magnifyingglass", tooltip: "Search AO3 for this fandom's works") { [weak self] in
            self?.model.searchFandomOnAO3()
        }
        fandomSearchBtn = button
        return button
    }

    func fandomLibraryBackButton() -> ToolButton {
        let button = fandomLibraryBackBtn ?? ToolButton(theme: theme, symbol: "arrow.left", tooltip: "Back to library works") { [weak self] in
            self?.model.showFandomLibraryWorks()
        }
        fandomLibraryBackBtn = button
        return button
    }

    /// Drill-in staleness line: "N works stored · refreshed 3d ago" when a
    /// full crawl has ever completed, plain count otherwise.
    func storedWorksSubtitle(count: Int, crawledAt: String?) -> String {
        let stored = "\(count) works stored"
        guard let crawledAt, !crawledAt.isEmpty else { return stored }
        return "\(stored) · refreshed \(Fmt.relativeTime(crawledAt))"
    }

    /// The drill-in header button: "Refresh Works" idle, "Cancel" while a
    /// crawl runs. render() re-invokes this every pass, so the label always
    /// tracks the current state.
    func refreshWorksButton(forAuthor: Bool) -> LabelToolButton {
        let button: LabelToolButton
        if forAuthor {
            button = authorRefreshBtn ?? LabelToolButton(theme: theme) { [weak self] in
                guard let model = self?.model else { return }
                if model.author.isLoadingWorks {
                    model.author.cancelWorksRefresh()
                } else {
                    // A stopped crawl picks up where it left off.
                    model.author.refreshWorks(resume: model.author.worksCrawlStop != nil)
                }
            }
            authorRefreshBtn = button
        } else {
            button = subscriptionRefreshBtn ?? LabelToolButton(theme: theme) { [weak self] in
                guard let model = self?.model else { return }
                if model.subscriptionWorks.isLoading {
                    model.subscriptionWorks.cancelRefresh()
                } else {
                    model.subscriptionWorks.refresh(resume: model.subscriptionWorks.crawlStop != nil)
                }
            }
            subscriptionRefreshBtn = button
        }
        let loading = forAuthor ? model.author.isLoadingWorks : model.subscriptionWorks.isLoading
        let stop = forAuthor ? model.author.worksCrawlStop : model.subscriptionWorks.crawlStop
        if loading {
            button.configure(title: "Cancel", symbol: "xmark",
                             tooltip: "Stop fetching — works fetched so far are kept, and it can resume")
        } else if let stop {
            button.configure(title: "Resume Works", symbol: "arrow.clockwise",
                             tooltip: "\(stop.label) — continue fetching from there")
        } else {
            button.configure(title: "Refresh Works", symbol: "arrow.clockwise",
                             tooltip: "Fetch this author’s complete works list from AO3, page by page")
        }
        return button
    }
}
