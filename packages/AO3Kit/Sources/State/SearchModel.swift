import Foundation
import Observation

/// State for AO3 search: the criteria form (scraped from AO3, persisted in
/// the encrypted database, re-scraped on demand) and paged results. Shared by
/// both apps; each renders it in its own containers.
@Observable
@MainActor
final class SearchModel {
    /// Stable session key so the form survives launches in the DB cache table.

    var formFields: [UFormField] = []
    var fieldValues: [String: String] = [:]
    var checkboxValues: [String: Set<String>] = [:]
    var isLoadingForm = false
    var formError: String?
    var hasSearched = false

    // MARK: - Scope tabs & source toggle

    /// What kind of thing the search targets — the title-bar tabs.
    enum SearchScope: String, CaseIterable {
        case works = "Works"
        case collections = "Collections"
        case bookmarks = "Bookmarks"
        case tags = "Tags"
        case users = "Users"
    }

    var scope: SearchScope = .works
    /// true (default) searches only what's already in the app's database;
    /// false runs a full search on AO3.
    var searchLibraryOnly = true
    /// Query text for the non-works scopes (Works keeps the criteria form).
    var scopeQuery = ""

    // Library-scope results. Works reuses the works results list
    // (appState.searchResults); these hold the other scopes' hits.
    var tagHits: [UTagHit] = []
    var userHits: [String] = []
    var collectionHits: [UCollection] = []
    /// Bookmark search hits (both sources): the bookmark's own fields plus
    /// the work blurb, rendered as bookmark rows.
    var bookmarkHits: [UBookmarkHit] = []
    /// Shown in the form when the scope+source combination can't run yet
    /// (AO3-side search for the non-works scopes).
    var scopeNotice: String?

    /// The in-flight AO3-side query (request-tracking standard) — its opID
    /// feeds the results pane's progress banner. Every AO3-side query runs
    /// tracked through `trackedFetch`, whatever triggered it: the scope
    /// forms, a clicked tag, and the collection drill-in listings alike.
    let searchFetchOp = TrackedOperation()

    /// The split collection view's bookmarks pane fetch, tracked apart from
    /// searchFetchOp: in split mode both listings fetch concurrently, and a
    /// TrackedOperation holds a single in-flight opID — sharing one would
    /// let each fetch clobber the other's banner. Each pane's overlay reads
    /// its own operation.
    let bookmarksFetchOp = TrackedOperation()

    /// The one search process for AO3-side queries: mint a tracked opID
    /// (progress banner) and run the bridge fetch under the standard
    /// timeout retry. Every trigger of every query type funnels through
    /// here so they all get identical progress UI and retry behavior.
    @MainActor
    func trackedFetch<T>(
        _ op: TrackedOperation,
        _ appState: AppState,
        _ body: @escaping (UInt64) async throws -> T
    ) async throws -> T {
        try await op.run(appState.bridge) { opID in
            try await appState.retryOnTimeout(task: appState.searchTask, using: appState.bridge) {
                try await body(opID)
            }
        }
    }

    /// Switch tabs: back to that scope's form, stale notice cleared, any
    /// split collection view dissolved.
    @MainActor
    func setScope(_ s: SearchScope) {
        guard s != scope else { return }
        scope = s
        scopeNotice = nil
        showingResults = false
        canReturnToCollectionHits = false
        collectionReturnQuery = nil
        closeSplitCollection()
    }

    // MARK: - Collections scope criteria (mirrors AO3's /collections
    // sort/filter form; scopeQuery doubles as the title filter)

    /// Comma-separated tag names (AO3 allows up to 5).
    var collectionTags = ""
    /// Tri-states: "" (either), "true", "false".
    var collectionMultifandom = ""
    var collectionClosed = ""
    var collectionModerated = ""
    /// "" (any), "GiftExchange", "PromptMeme", "no_challenge".
    var collectionChallengeType = ""
    var collectionSortColumn = "created_at"
    var collectionSortDirection = "desc"

    /// The collections form state as criteria for either source: sent to
    /// AO3 as collection_search[...] params, or evaluated against the
    /// cached collections by the core.
    func collectionCriteria() -> UCollectionSearchCriteria {
        UCollectionSearchCriteria(
            title: scopeQuery.trimmingCharacters(in: .whitespaces),
            tag: collectionTags.trimmingCharacters(in: .whitespaces),
            multifandom: collectionMultifandom,
            closed: collectionClosed,
            moderated: collectionModerated,
            challengeType: collectionChallengeType,
            sortColumn: collectionSortColumn,
            sortDirection: collectionSortDirection)
    }

    // MARK: - Bookmarks scope criteria (mirrors AO3's /bookmarks/search
    // form; scopeQuery doubles as the "any field on work" query)

    /// Comma-separated work tag names.
    var bookmarkWorkTags = ""
    /// "" (any), "Work", "Series", "External Work".
    var bookmarkType = ""
    /// AO3 numeric range syntax, e.g. ">10000".
    var bookmarkWordCount = ""
    /// AO3 language value ("en"); "" = any. Options come from the scraped
    /// works form's language select.
    var bookmarkLanguage = ""
    /// Work's Date Updated expression.
    var bookmarkDateUpdated = ""
    /// Any field on the bookmark itself.
    var bookmarkQuery = ""
    /// Comma-separated bookmarker's tag names.
    var bookmarkerTags = ""
    var bookmarkBookmarker = ""
    var bookmarkNotes = ""
    var bookmarkRecOnly = false
    var bookmarkWithNotesOnly = false
    /// Date Bookmarked expression.
    var bookmarkDate = ""
    /// "" (Best Match), "created_at", "bookmarkable_date", "word_count".
    var bookmarkSortColumn = "created_at"

    /// The bookmarks form state as criteria for either source. AO3 wants
    /// its language value ("en"); the library matches the language *name*
    /// on cached works, so library mode translates the selected value to
    /// its label via the scraped form's options.
    func bookmarkCriteria(forLibrary: Bool) -> UBookmarkSearchCriteria {
        var language = bookmarkLanguage
        if forLibrary, !language.isEmpty {
            language = formFields.first { $0.name.contains("[language_id]") }?
                .options.first { $0.value == language }?
                .label.trimmingCharacters(in: .whitespaces) ?? language
        }
        return UBookmarkSearchCriteria(
            bookmarkableQuery: scopeQuery.trimmingCharacters(in: .whitespaces),
            otherTagNames: bookmarkWorkTags.trimmingCharacters(in: .whitespaces),
            bookmarkableType: bookmarkType,
            wordCount: bookmarkWordCount.trimmingCharacters(in: .whitespaces),
            languageId: language,
            bookmarkableDate: bookmarkDateUpdated.trimmingCharacters(in: .whitespaces),
            bookmarkQuery: bookmarkQuery.trimmingCharacters(in: .whitespaces),
            otherBookmarkTagNames: bookmarkerTags.trimmingCharacters(in: .whitespaces),
            bookmarker: bookmarkBookmarker.trimmingCharacters(in: .whitespaces),
            bookmarkNotes: bookmarkNotes.trimmingCharacters(in: .whitespaces),
            rec: bookmarkRecOnly,
            withNotes: bookmarkWithNotesOnly,
            date: bookmarkDate.trimmingCharacters(in: .whitespaces),
            sortColumn: bookmarkSortColumn)
    }

    // MARK: - Bookmark results list filter (client-side sieve over the
    // hits, the bookmark-results twin of the works lists' header filter)

    struct BookmarkListFilter {
        var text = ""
        /// Numeric filters accepting ">" / "<" prefixes (plain number = at least).
        var kudos = ""
        var words = ""
        /// Matches the work's tags or the bookmarker's own tags.
        var tags: Set<String> = []
        var fandoms: Set<String> = []
        var bookmarker = ""
        var note = ""
        /// Substring over the displayed date ("10 Aug 2026" / "2026-08-10").
        var date = ""
        var isActive: Bool {
            ![text, kudos, words, bookmarker, note, date]
                .allSatisfy { $0.trimmingCharacters(in: .whitespaces).isEmpty }
                || !tags.isEmpty || !fandoms.isEmpty
        }
    }

    var bookmarkListFilter = BookmarkListFilter()

    /// The hits after the header filter — what the results view renders.
    var filteredBookmarkHits: [UBookmarkHit] {
        let f = bookmarkListFilter
        guard f.isActive else { return bookmarkHits }
        return bookmarkHits.filter { Self.matches(f, $0) }
    }

    private static func matches(_ f: BookmarkListFilter, _ hit: UBookmarkHit) -> Bool {
        func ci(_ hay: String, _ needle: String) -> Bool {
            hay.localizedCaseInsensitiveContains(needle)
        }
        let text = f.text.trimmingCharacters(in: .whitespaces)
        if !text.isEmpty {
            if !(ci(hit.displayTitle, text) || hit.displayAuthors.contains { ci($0, text) }
                 || ci(hit.displaySummary, text)) {
                return false
            }
        }
        if !Self.numberMatches(f.kudos, value: UInt64(hit.displayKudos)) { return false }
        if !Self.numberMatches(f.words, value: hit.displayWordCount) { return false }
        if !f.tags.isEmpty {
            let all = hit.displayWorkTags + hit.tags
            for tag in f.tags
            where !all.contains(where: { $0.caseInsensitiveCompare(tag) == .orderedSame }) {
                return false
            }
        }
        for fandom in f.fandoms
        where !hit.displayFandoms.contains(where: { $0.caseInsensitiveCompare(fandom) == .orderedSame }) {
            return false
        }
        let who = f.bookmarker.trimmingCharacters(in: .whitespaces)
        if !who.isEmpty && !ci(hit.bookmarker, who) { return false }
        let note = f.note.trimmingCharacters(in: .whitespaces)
        if !note.isEmpty && !ci(hit.note, note) { return false }
        let date = f.date.trimmingCharacters(in: .whitespaces)
        if !date.isEmpty && !ci(hit.dateBookmarked, date) { return false }
        return true
    }

    /// ">" / "<"-prefixed numeric expressions, plain number = at least —
    /// the work-list filter grammar. Unparseable expressions don't filter.
    private static func numberMatches(_ expr: String, value: UInt64) -> Bool {
        let e = expr.filter { $0 != "," && !$0.isWhitespace }
        guard !e.isEmpty else { return true }
        if e.hasPrefix(">") {
            guard let n = UInt64(e.dropFirst()) else { return true }
            return value > n
        }
        if e.hasPrefix("<") {
            guard let n = UInt64(e.dropFirst()) else { return true }
            return value < n
        }
        guard let n = UInt64(e) else { return true }
        return value >= n
    }

    /// Suggestion pools for the filter popover, drawn from the current
    /// (pre-filter) hits — work tags of every category plus the
    /// bookmarkers' own tags.
    var bookmarkFilterTagPool: [String] {
        Set(bookmarkHits.flatMap { $0.displayWorkTags + $0.tags })
            .sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
    }

    var bookmarkFilterFandomPool: [String] {
        Set(bookmarkHits.flatMap(\.displayFandoms))
            .sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
    }

    /// What the current results represent — the form's criteria, a tag
    /// (fandom card / tag pill), a collection's works (by URL slug), or
    /// the collections index under the collections form's criteria.
    /// Pagination re-runs whichever is active.
    enum ActiveQuery {
        case form(keys: [String], values: [String])
        case tag(String)
        case collection(String)
        case collectionBookmarks(String)
        case collectionsIndex(UCollectionSearchCriteria)
        case bookmarkSearch(UBookmarkSearchCriteria)
    }

    var activeQuery: ActiveQuery?
    /// The tab that was current when the active query was started. Tag and
    /// collection drill-ins flip the visible scope to Works so the works
    /// table renders; the back arrow restores this, returning to the form
    /// of the tab that initiated the search.
    var originScope: SearchScope?

    // MARK: - Split collection results (works | bookmarks, side by side)

    /// Non-nil while a collection with both works and bookmarked items is
    /// open from the search results: the results area splits into a works
    /// pane (the shared works-results state) and a bookmarks pane (the
    /// bookmark* state below), each paged independently.
    var splitCollectionName: String?
    var splitCollectionTitle: String?
    /// What the collections results list was showing, restored when the
    /// split closes so its pager keeps working.
    var splitReturnQuery: ActiveQuery?

    /// Set while a single-pane collection drill-in was opened from the
    /// collections hit list: the results back arrow pops back to that
    /// list (splitReturnQuery's counterpart for the no-split case) before
    /// a second press reaches the form.
    var canReturnToCollectionHits = false
    /// The hit list's query, restored on that pop so its pager keeps
    /// working (nil for library hit lists, whose pager is inert).
    var collectionReturnQuery: ActiveQuery?

    var bookmarkResults: [Work] = []
    var bookmarksPage: UInt32 = 1
    var bookmarksHasNext = false
    var bookmarksTotalPages: UInt32 = 1
    var bookmarksTotal: UInt32?
    var isFetchingBookmarks = false
    var bookmarksError: String?

    /// The split's back arrow: dissolve both panes and return to the
    /// collections results list (still held in collectionHits).
    @MainActor
    func closeSplitCollection() {
        guard splitCollectionName != nil else { return }
        splitCollectionName = nil
        splitCollectionTitle = nil
        activeQuery = splitReturnQuery
        splitReturnQuery = nil
        bookmarkResults = []
        bookmarksError = nil
    }

    /// The results header's back arrow: one level out — back to the
    /// collections hit list when a drill-in came from one, back to the
    /// initiating tab's form otherwise.
    @MainActor
    func returnToForm() {
        if canReturnToCollectionHits {
            canReturnToCollectionHits = false
            activeQuery = collectionReturnQuery
            collectionReturnQuery = nil
            if let originScope { scope = originScope }
            return
        }
        if let originScope { scope = originScope }
        showingResults = false
        closeSplitCollection()
    }

    var currentPage: UInt32 = 1
    /// From the results page's own pagination — a page-size heuristic showed
    /// a false next arrow whenever a final page held exactly 20 works.
    var hasNextPage = false
    /// Total pages per the results pagination bar (1 when unpaginated).
    var totalPages: UInt32 = 1
    /// The results page's own count ("834 Found"); nil when absent.
    var totalWorks: UInt32?

    /// Toolbar subtitle for a results page: "Page 3 of 42 · 834 works",
    /// degrading gracefully when parts are unknown.
    var resultsSubtitle: String? {
        guard hasSearched else { return nil }
        var line = totalPages > 1 ? "Page \(currentPage) of \(totalPages)" : "Page \(currentPage)"
        if let total = totalWorks {
            line += total == 1 ? " · 1 work" : " · \(total) works"
        }
        return line
    }

    var primaryField: UFormField? {
        formFields.first { $0.fieldType == "text" && $0.name.contains("[query]") }
    }

    /// Everything except the primary query and hidden fields.
    var filterFields: [UFormField] {
        formFields.filter { $0.name != primaryField?.name && $0.fieldType != "hidden" }
    }

    var queryText: String {
        get { primaryField.flatMap { fieldValues[$0.name] } ?? fieldValues["work_search[query]"] ?? "" }
        set {
            let key = primaryField?.name ?? "work_search[query]"
            fieldValues[key] = newValue
        }
    }

    func setQuery(_ text: String) {
        queryText = text
    }

    /// The auto-applied device-language default (field name → value). Not a
    /// user choice, so it must not count as an "active filter" — counting it
    /// made the badge read "1 filters active" on a pristine form, and Clear
    /// (which re-applies the default) could never bring it to zero.
    private var defaultLanguage: (field: String, value: String)?

    var activeFilterCount: Int {
        let fields = fieldValues.filter { key, value in
            guard key != primaryField?.name, !value.isEmpty else { return false }
            if let defaultLanguage, key == defaultLanguage.field, value == defaultLanguage.value {
                return false
            }
            return true
        }.count
        let checkboxes = checkboxValues.reduce(0) { $0 + $1.value.count }
        return fields + checkboxes
    }

    // MARK: - Form: database-first, scraped from AO3 on demand

    @MainActor
    func loadFormIfNeeded(_ appState: AppState) async {
        guard formFields.isEmpty else { return }
        if loadCachedFormIfAvailable(appState) { return }
        await scrapeForm(appState)
    }

    /// Cache-only form load — no network, ever. The bookmarks form uses
    /// this so its language options appear whenever the works form has
    /// been scraped before, without triggering a fetch of its own.
    @MainActor
    @discardableResult
    func loadCachedFormIfAvailable(_ appState: AppState) -> Bool {
        guard formFields.isEmpty else { return true }
        guard let fields = SearchFormCache.load(appState.bridge) else { return false }
        formFields = fields
        applyDefaultLanguageIfUnset()
        return true
    }

    /// Default the language filter to the device's language. AO3's language
    /// ids are a mix of ISO 639-1/2/3 codes plus specials like "ptBR", so try
    /// the compacted full tag, then the alpha-2 code, then alpha-3, and leave
    /// the field untouched ("Any") when none of them is offered.
    private func applyDefaultLanguageIfUnset() {
        guard let field = formFields.first(where: { $0.name.contains("[language_id]") }),
              (fieldValues[field.name] ?? "").isEmpty else { return }
        let preferred = Locale.preferredLanguages.first ?? "en"
        let language = Locale.Language(identifier: preferred)
        var candidates = [preferred.replacingOccurrences(of: "-", with: "")]
        if let code = language.languageCode {
            candidates.append(code.identifier)
            if let alpha3 = code.identifier(.alpha3) {
                candidates.append(alpha3)
            }
        }
        let values = Set(field.options.map(\.value).filter { !$0.isEmpty })
        if let match = candidates.first(where: { values.contains($0) }) {
            fieldValues[field.name] = match
            defaultLanguage = (field.name, match)
        }
    }

    /// Re-scrape the criteria fields from AO3 and persist them (header button).
    @MainActor
    func scrapeForm(_ appState: AppState) async {
        guard appState.bridge.isInitialized, !appState.bridge.networkBlocked else {
            formError = "Connect first to load the search fields from AO3."
            return
        }
        guard !isLoadingForm else { return }
        isLoadingForm = true
        formError = nil
        do {
            let fields = try await appState.retryOnTimeout(task: appState.searchTask, using: appState.bridge) {
                try await appState.bridge.fetchSearchForm()
            }
            formFields = fields
            applyDefaultLanguageIfUnset()
            SearchFormCache.store(fields, appState.bridge)
        } catch {
            if !appState.searchTask.isCancelled && !error.isCancellation {
                formError = error.localizedDescription
            }
        }
        isLoadingForm = false
    }

    // MARK: - Searching & pagination (page fetches replace results)

    /// Starting a brand-new query drops the previous query's results before
    /// anything renders: the results pane must show search progress, never a
    /// stale list from the last search. (Pagination within a query keeps the
    /// current page visible instead — only new queries clear.)
    @MainActor
    /// Search-section pane state: false shows the full-width criteria form
    /// in the reading pane, true shows the results list. Executing any
    /// query flips to results; the header's back button returns to the form.
    var showingResults = false

    /// Called when a query discards the previous results. MacAppModel hangs
    /// the list-filter reset off this — paging keeps the filter, a new query
    /// does not.
    var onNewQuery: (() -> Void)?

    /// The core-side handle for the library works result set currently in
    /// the results pane (run_library_search). Released whenever something
    /// else replaces those results; the core's LRU cap backstops handles a
    /// teardown never releases.
    var librarySearchHandle: UInt64?

    @MainActor
    func releaseLibrarySearch(_ appState: AppState) {
        if let handle = librarySearchHandle {
            appState.bridge.dropLibrarySearch(handle)
            librarySearchHandle = nil
        }
    }

    @MainActor
    func beginNewQuery(_ appState: AppState) {
        releaseLibrarySearch(appState)
        onNewQuery?()
        canReturnToCollectionHits = false
        collectionReturnQuery = nil
        appState.searchResults = []
        appState.searchError = nil
        appState.isSearching = true
        tagHits = []
        userHits = []
        collectionHits = []
        bookmarkHits = []
        currentPage = 1
        hasNextPage = false
        totalPages = 1
        totalWorks = nil
        showingResults = true
    }

    /// The Go button and every form's Return key land here: dispatch by
    /// scope tab and library/AO3 toggle. Library scopes are synchronous
    /// reads of the encrypted database — no network, per the toggle's
    /// promise. AO3-side search exists for Works and Collections so far;
    /// the other scopes surface a notice instead of failing silently.
    @MainActor
    func performScopedSearch(_ appState: AppState) {
        scopeNotice = nil
        originScope = scope
        switch (scope, searchLibraryOnly) {
        case (.works, _):
            // The form is one producer of a works request like any other
            // trigger — snapshot it and hand it to the works-search API.
            runWorksSearch(formRequest(), appState: appState)
        case (.bookmarks, true):
            // The full bookmark-search form against the cached bookmark
            // rows — hits render as bookmark rows, not plain works.
            beginLibraryScopeResults(appState)
            bookmarkHits = appState.bridge.searchLibraryBookmarksFiltered(bookmarkCriteria(forLibrary: true))
            totalWorks = UInt32(bookmarkHits.count)
        case (.bookmarks, false):
            // AO3's /bookmarks/search under the same form — paged, so it
            // runs through activeQuery like the works queries.
            activeQuery = .bookmarkSearch(bookmarkCriteria(forLibrary: false))
            beginNewQuery(appState)
            Task { await fetch(page: 1, appState: appState) }
        case (.tags, true):
            beginLibraryScopeResults(appState)
            tagHits = appState.bridge.searchLibraryTags(scopeQuery)
        case (.users, true):
            beginLibraryScopeResults(appState)
            userHits = appState.bridge.searchLibraryUsers(scopeQuery)
        case (.collections, true):
            beginLibraryScopeResults(appState)
            collectionHits = appState.bridge.searchLibraryCollectionsFiltered(collectionCriteria())
        case (.collections, false):
            // The collections index under the form's criteria — paged, so
            // it runs through activeQuery like the works queries.
            activeQuery = .collectionsIndex(collectionCriteria())
            beginNewQuery(appState)
            Task { await fetch(page: 1, appState: appState) }
        case (.tags, false), (.users, false):
            scopeNotice = "Searching AO3 for \(scope.rawValue.lowercased()) isn't available yet — switch the source toggle to search your library."
        }
    }

    // MARK: - Works search API (the one entry point for works searches)

    /// Every Search→Works criterion as one value: field values keyed by
    /// AO3's form field names plus the checkbox-group selections. The
    /// form's Go press snapshots the visible form into one; programmatic
    /// triggers (tag clicks, the sidebar quick search, sort re-runs)
    /// construct or amend one directly — the form's stored state is never
    /// touched, so backing out of programmatic results shows the form as
    /// the user left it.
    struct WorksSearchRequest {
        var fieldValues: [String: String] = [:]
        var checkboxValues: [String: Set<String>] = [:]
    }

    /// The visible form state as a request — what the Go button submits.
    func formRequest() -> WorksSearchRequest {
        WorksSearchRequest(fieldValues: fieldValues, checkboxValues: checkboxValues)
    }

    /// The request behind the works results currently showing. Sort
    /// re-runs amend this, so refining programmatically triggered results
    /// never falls back to the form's criteria.
    var activeWorksRequest: WorksSearchRequest?

    func clearFilters() {
        let query = queryText
        fieldValues = [:]
        checkboxValues = [:]
        setQuery(query)
        // The form's default state includes the device language.
        applyDefaultLanguageIfUnset()
    }

    // MARK: - Saved searches (criteria persisted in the encrypted DB)

    var savedSearches: [USavedSearch] = []

}
