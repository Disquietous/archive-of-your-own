import Foundation

extension SearchModel {
    /// The works-search API: execute `request` under the library/AO3
    /// source toggle and show the results view. Every works-search
    /// trigger funnels through here.
    @MainActor
    func runWorksSearch(_ request: WorksSearchRequest, appState: AppState) {
        scopeNotice = nil
        originScope = scope
        scope = .works
        activeWorksRequest = request
        if searchLibraryOnly {
            runLibraryWorksSearch(appState, criteria: libraryCriteria(from: request))
            return
        }
        var keys: [String] = []
        var values: [String] = []
        for (name, value) in request.fieldValues where !value.isEmpty {
            keys.append(name)
            values.append(value)
        }
        for (name, selected) in request.checkboxValues {
            for value in selected {
                keys.append(name)
                values.append(value)
            }
        }
        activeQuery = .form(keys: keys, values: values)
        beginNewQuery(appState)
        Task { await fetch(page: 1, appState: appState) }
    }

    /// Re-run the current works results with one field changed (the
    /// results header's server-side sort menu). No-op when no works
    /// request has run.
    @MainActor
    func updateWorksSearchField(_ name: String, value: String, appState: AppState) {
        guard var request = activeWorksRequest else { return }
        request.fieldValues[name] = value
        runWorksSearch(request, appState: appState)
    }

    /// The library/AO3 source toggle. Flipped while search results are
    /// showing, the results clear and the same search re-runs under the
    /// new source — works results re-run their active request, the other
    /// scopes re-run their form criteria. Drill-in listings (a tag's AO3
    /// browse, a collection's works, the split view) aren't re-runnable
    /// searches, and the forms just pick up the new value on the next Go.
    @MainActor
    func toggleSearchSource(_ appState: AppState) {
        searchLibraryOnly.toggle()
        guard showingResults, splitCollectionName == nil, !canReturnToCollectionHits else { return }
        if scope == .works {
            switch activeQuery {
            case .form, nil:
                if let request = activeWorksRequest {
                    runWorksSearch(request, appState: appState)
                }
            default:
                break
            }
        } else {
            performScopedSearch(appState)
        }
    }

    /// A clicked tag (pill, fandom card, tag hit): a one-criterion works
    /// request — the tag in the field matching its library-known category,
    /// Additional Tags when unknown — through the works-search API. The
    /// visible form is neither shown nor touched.
    @MainActor
    func startTagQuery(_ tag: String, appState: AppState) {
        let tagType = appState.bridge.searchLibraryTags(tag)
            .first { $0.name.caseInsensitiveCompare(tag) == .orderedSame }?
            .tagType
        let suffix = switch tagType {
        case "fandom": "[fandom_names]"
        case "character": "[character_names]"
        case "relationship": "[relationship_names]"
        default: "[freeform_names]"
        }
        let field = formFields.first { $0.name.hasSuffix(suffix) }?.name ?? "work_search\(suffix)"
        runWorksSearch(WorksSearchRequest(fieldValues: [field: tag]), appState: appState)
    }

    /// AO3's tag-browse listing (/tags/…/works), paged — the explicitly
    /// AO3-side listing behind the fandom drill-in's "Search AO3" button,
    /// which bypasses the source toggle by design.
    @MainActor
    func startAO3TagListing(_ tag: String, appState: AppState) {
        // Tag/collection listings are works results — land on the Works tab
        // whatever scope the search section was left on. The pre-flip scope
        // is where the back arrow returns.
        originScope = scope
        scope = .works
        activeQuery = .tag(tag)
        beginNewQuery(appState)
        Task { await fetch(page: 1, appState: appState) }
    }

    /// A collection's works — `name` is the /collections/{name} slug.
    /// Library mode reads what this collection's cached listings already
    /// recorded (no network, per the source toggle's promise) — split into
    /// works and bookmarks panes when both were cached, a single pane
    /// otherwise. AO3 mode fetches the live listing, paged. When the
    /// caller knows the collection holds both works and bookmarked items,
    /// AO3 mode splits the results view — works pane and bookmarks pane,
    /// first pages loaded simultaneously, paged independently. A
    /// bookmarks-only collection pages its /bookmarks listing in the
    /// single results pane instead. `fromHitList` marks a drill-in from
    /// the collections hit list: the single-pane paths then keep the hit
    /// list behind the results so the back arrow pops to it (the split
    /// paths already do, via splitReturnQuery).
    @MainActor
    func startCollectionQuery(_ name: String, title: String = "",
                              workCount: UInt32 = 0, bookmarkedCount: UInt32 = 0,
                              fromHitList: Bool = false,
                              appState: AppState) {
        let hitListQuery = activeQuery
        let hits = collectionHits
        if searchLibraryOnly {
            let works = appState.bridge.getLibraryCollectionWorks(name: name)
                .map(AppState.workFromSummary)
            // Library-mode panes are works lists; series bookmarks have
            // no row here.
            let bookmarks = appState.bridge.getLibraryCollectionBookmarks(name: name)
                .compactMap(\.work).map(AppState.workFromSummary)
            if works.isEmpty || bookmarks.isEmpty {
                originScope = scope
                scope = .works
                presentLibraryWorks(works.isEmpty ? bookmarks : works, appState: appState)
                if fromHitList {
                    collectionHits = hits
                    collectionReturnQuery = hitListQuery
                    canReturnToCollectionHits = true
                }
                return
            }
            // Library split: both panes land at once from the cache, the
            // pagers stay inert (activeQuery nil, single page each).
            splitReturnQuery = activeQuery
            splitCollectionName = name
            splitCollectionTitle = title.isEmpty ? name : title
            activeQuery = nil
            onNewQuery?()
            appState.searchResults = works
            appState.searchError = nil
            currentPage = 1
            hasNextPage = false
            totalPages = 1
            totalWorks = UInt32(works.count)
            bookmarkResults = bookmarks
            bookmarksPage = 1
            bookmarksHasNext = false
            bookmarksTotalPages = 1
            bookmarksTotal = UInt32(bookmarks.count)
            bookmarksError = nil
            hasSearched = true
            showingResults = true
            return
        }
        if workCount > 0, bookmarkedCount > 0 {
            // Split mode: the scope stays on Collections and the hit list
            // survives untouched behind the panes — the works pane's back
            // arrow returns straight to it.
            splitReturnQuery = activeQuery
            splitCollectionName = name
            splitCollectionTitle = title.isEmpty ? name : title
            activeQuery = .collection(name)
            onNewQuery?()
            appState.searchResults = []
            appState.searchError = nil
            appState.isSearching = true
            currentPage = 1
            hasNextPage = false
            totalPages = 1
            totalWorks = nil
            bookmarkResults = []
            bookmarksPage = 1
            bookmarksHasNext = false
            bookmarksTotalPages = 1
            bookmarksTotal = nil
            bookmarksError = nil
            hasSearched = true
            showingResults = true
            Task { await fetch(page: 1, appState: appState) }
            Task { await fetchBookmarksPage(1, appState: appState) }
        } else {
            originScope = scope
            scope = .works
            // A bookmarks-only collection has an empty /works listing —
            // its items live under /bookmarks, so page that instead.
            activeQuery = (workCount == 0 && bookmarkedCount > 0)
                ? .collectionBookmarks(name) : .collection(name)
            beginNewQuery(appState)
            if fromHitList {
                collectionHits = hits
                collectionReturnQuery = hitListQuery
                canReturnToCollectionHits = true
            }
            Task { await fetch(page: 1, appState: appState) }
        }
        // Cache the collection's profile metadata + tags. This is the one
        // shared entry point for opening a collection (browse list and
        // search results both land here); the core answers from the
        // database after the first fetch, so it's one request per
        // collection, ever. AO3 mode only — the profile fetch is a
        // network op.
        Task { @MainActor in
            _ = try? await appState.bridge.ensureCollectionProfile(name: name)
        }
    }

    /// The bookmarks pane's pager.
    @MainActor
    func goToBookmarksPage(_ page: UInt32, appState: AppState) {
        guard page >= 1, splitCollectionName != nil, !isFetchingBookmarks else { return }
        Task { await fetchBookmarksPage(page, appState: appState) }
    }

    /// A bookmark listing page as a works page — the work-row panes show
    /// the bookmarked works; series bookmarks (cached by the core) have no
    /// row in a works list.
    private static func worksPage(_ page: UPagedBookmarks) -> UPagedWorks {
        UPagedWorks(works: page.bookmarks.compactMap(\.work),
                    hasNextPage: page.hasNextPage,
                    totalPages: page.totalPages,
                    totalWorks: page.totalFound)
    }

    @MainActor
    private func fetchBookmarksPage(_ page: UInt32, appState: AppState) async {
        guard let name = splitCollectionName else { return }
        isFetchingBookmarks = true
        bookmarksError = nil
        do {
            let result = Self.worksPage(try await trackedFetch(bookmarksFetchOp, appState) { opID in
                try await appState.bridge.fetchCollectionBookmarks(name: name, page: page, opID: opID)
            })
            bookmarkResults = result.works.map(AppState.workFromSummary)
            bookmarksPage = page
            bookmarksHasNext = result.hasNextPage
            bookmarksTotalPages = max(result.totalPages, page)
            bookmarksTotal = result.totalWorks
            // Fetched works are persisted by the Rust layer — merge them
            // into the library snapshot so they join local lists at once.
            appState.mergeCachedWorks(bookmarkResults)
        } catch {
            if !appState.searchTask.isCancelled && !error.isCancellation {
                bookmarksError = error.localizedDescription
            }
        }
        isFetchingBookmarks = false
    }

    @MainActor
    func goToPage(_ page: UInt32, appState: AppState) {
        guard page >= 1, activeQuery != nil, !appState.isSearching else { return }
        Task { await fetch(page: page, appState: appState) }
    }

    @MainActor
    func fetch(page: UInt32, appState: AppState) async {
        guard let query = activeQuery else { return }
        hasSearched = true
        appState.isSearching = true
        appState.searchError = nil
        do {
            switch query {
            case .form(let keys, let values):
                applyWorksPage(try await trackedFetch(searchFetchOp, appState) { opID in
                    try await appState.bridge.searchWorksRawPaged(keys: keys, values: values, page: page, opID: opID)
                }, page: page, appState: appState)
            case .tag(let tag):
                applyWorksPage(try await trackedFetch(searchFetchOp, appState) { opID in
                    try await appState.bridge.searchByTagPaged(tag, page: page, opID: opID)
                }, page: page, appState: appState)
            case .collection(let name):
                applyWorksPage(try await trackedFetch(searchFetchOp, appState) { opID in
                    try await appState.bridge.fetchCollectionWorks(name: name, page: page, opID: opID)
                }, page: page, appState: appState)
            case .collectionBookmarks(let name):
                applyWorksPage(Self.worksPage(try await trackedFetch(searchFetchOp, appState) { opID in
                    try await appState.bridge.fetchCollectionBookmarks(name: name, page: page, opID: opID)
                }), page: page, appState: appState)
            case .bookmarkSearch(let criteria):
                let result = try await trackedFetch(searchFetchOp, appState) { opID in
                    try await appState.bridge.searchBookmarks(criteria: criteria, page: page, opID: opID)
                }
                bookmarkHits = result.bookmarks
                totalWorks = result.totalFound
                currentPage = page
                hasNextPage = result.hasNextPage
                totalPages = max(result.totalPages, page)
                // Fetched works are persisted by the Rust layer — merge
                // them into the library snapshot so they join local lists.
                appState.mergeCachedWorks(result.bookmarks.compactMap(\.work))
            case .collectionsIndex(let criteria):
                let result = try await trackedFetch(searchFetchOp, appState) { opID in
                    try await appState.bridge.browseCollections(criteria: criteria, page: page, opID: opID)
                }
                collectionHits = result.collections
                totalWorks = nil
                currentPage = page
                hasNextPage = result.hasNextPage
                totalPages = max(result.totalPages, page)
            }
        } catch {
            if !appState.searchTask.isCancelled && !error.isCancellation {
                appState.searchError = error.localizedDescription
            }
        }
        appState.isSearching = false
    }

    /// Land one page of works-style results (Works form, tag listing, a
    /// collection's works) in the shared works results pane.
    @MainActor
    private func applyWorksPage(_ result: UPagedWorks, page: UInt32, appState: AppState) {
        appState.searchResults = result.works.map(AppState.workFromSummary)
        totalWorks = result.totalWorks
        currentPage = page
        hasNextPage = result.hasNextPage
        totalPages = max(result.totalPages, page)
        // Results are persisted by the Rust layer as they're fetched —
        // merge them into the library snapshot so they join local lists.
        appState.mergeCachedWorks(appState.searchResults)
    }
}
