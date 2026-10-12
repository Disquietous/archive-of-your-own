import Foundation

extension SearchModel {
    /// An all-blank criteria record (blank matches everything in the core).
    static func emptyLibraryCriteria() -> ULibrarySearchCriteria {
        ULibrarySearchCriteria(
            query: "", title: "", creators: "", revisedAt: "", complete: "",
            crossover: "", singleChapter: false, wordCount: "", language: "",
            fandomNames: "", characterNames: "", relationshipNames: "",
            freeformNames: "", ratings: [], warnings: [], categories: [],
            hits: "", kudosCount: "", commentsCount: "", bookmarksCount: "",
            sortColumn: "", sortDirection: "")
    }

    /// A works request as label-based criteria for the local library
    /// search. Select and checkbox choices are stored as AO3's option
    /// values (numeric ids); the scraped form knows each value's label,
    /// and the core matches on names — translate here so the Rust side
    /// never needs AO3's id tables.
    @MainActor
    // swiftlint:disable:next cyclomatic_complexity
    func libraryCriteria(from request: WorksSearchRequest) -> ULibrarySearchCriteria {
        var c = Self.emptyLibraryCriteria()
        // Selected option values → their labels, for id-valued controls —
        // via the scraped form when it's loaded; raw values pass through
        // otherwise. Driven by the request's own keys, never formFields,
        // so programmatic requests (a tag click) match correctly even
        // when the form was never scraped.
        func labels(_ name: String, _ value: String, _ checked: Set<String>) -> [String] {
            let values = checked.isEmpty ? (value.isEmpty ? [] : [value]) : Array(checked)
            guard let field = formFields.first(where: { $0.name == name }) else { return values }
            return values.compactMap { v in
                field.options.first { $0.value == v }?.label
                    .trimmingCharacters(in: .whitespaces)
            }.filter { !$0.isEmpty }
        }
        for name in Set(request.fieldValues.keys).union(request.checkboxValues.keys) {
            let value = (request.fieldValues[name] ?? "").trimmingCharacters(in: .whitespaces)
            let checked = request.checkboxValues[name] ?? []
            switch name {
            case _ where name.hasSuffix("[query]"): c.query = value
            case _ where name.hasSuffix("[title]"): c.title = value
            case _ where name.hasSuffix("[creators]"): c.creators = value
            case _ where name.hasSuffix("[revised_at]"): c.revisedAt = value
            case _ where name.hasSuffix("[complete]"): c.complete = value
            case _ where name.hasSuffix("[crossover]"): c.crossover = value
            case _ where name.hasSuffix("[single_chapter]"): c.singleChapter = checked.contains("1") || value == "1"
            case _ where name.hasSuffix("[word_count]"): c.wordCount = value
            case _ where name.hasSuffix("[language_id]"): c.language = labels(name, value, checked).first ?? ""
            case _ where name.hasSuffix("[fandom_names]"): c.fandomNames = value
            case _ where name.hasSuffix("[character_names]"): c.characterNames = value
            case _ where name.hasSuffix("[relationship_names]"): c.relationshipNames = value
            case _ where name.hasSuffix("[freeform_names]"): c.freeformNames = value
            case _ where name.contains("[rating_ids]"): c.ratings = labels(name, value, checked)
            case _ where name.contains("[archive_warning_ids]"): c.warnings = labels(name, value, checked)
            case _ where name.contains("[category_ids]"): c.categories = labels(name, value, checked)
            case _ where name.hasSuffix("[hits]"): c.hits = value
            case _ where name.hasSuffix("[kudos_count]"): c.kudosCount = value
            case _ where name.hasSuffix("[comments_count]"): c.commentsCount = value
            case _ where name.hasSuffix("[bookmarks_count]"): c.bookmarksCount = value
            case _ where name.hasSuffix("[sort_column]"): c.sortColumn = value
            case _ where name.hasSuffix("[sort_direction]"): c.sortDirection = value
            default: break
            }
        }
        return c
    }

    /// Library mode for Works: evaluate the form's criteria against the
    /// cached works and reuse the works results pane. No pagination — the
    /// library returns everything at once (activeQuery stays nil so the
    /// pager stays inert).
    @MainActor
    func runLibraryWorksSearch(_ appState: AppState, criteria: ULibrarySearchCriteria) {
        guard let search = appState.bridge.runLibrarySearch(criteria) else {
            presentLibraryWorks([], appState: appState)
            return
        }
        // Show-everything presentation: hydrate the full range in one page.
        // The handle stays live so future paging can slice for free.
        let works = appState.bridge.getLibrarySearchPage(search.handle)
            .map(AppState.workFromSummary)
        presentLibraryWorks(works, appState: appState) // releases any prior handle
        librarySearchHandle = search.handle
    }

    /// Land a library (no-network) result set in the works results pane.
    /// activeQuery stays nil so the pager stays inert — library reads
    /// return everything at once.
    @MainActor
    func presentLibraryWorks(_ works: [Work], appState: AppState) {
        releaseLibrarySearch(appState)
        onNewQuery?()
        canReturnToCollectionHits = false
        collectionReturnQuery = nil
        activeQuery = nil
        appState.searchError = nil
        appState.searchResults = works
        currentPage = 1
        hasNextPage = false
        totalPages = 1
        totalWorks = UInt32(works.count)
        hasSearched = true
        showingResults = true
    }

    @MainActor
    func beginLibraryScopeResults(_ appState: AppState) {
        releaseLibrarySearch(appState)
        onNewQuery?()
        // Library reads aren't paged — a stale AO3 query must not leave
        // the pager live over library results.
        activeQuery = nil
        tagHits = []
        userHits = []
        collectionHits = []
        bookmarkHits = []
        currentPage = 1
        hasNextPage = false
        totalPages = 1
        totalWorks = nil
        hasSearched = true
        showingResults = true
    }
}
