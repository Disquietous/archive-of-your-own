import Foundation
import Observation

/// State for AO3 search: the criteria form (scraped from AO3, persisted in
/// the encrypted database, re-scraped on demand) and paged results shown in
/// the reading pane.
@Observable
final class MacSearchModel {
    /// Stable session key so the form survives launches in the DB cache table.
    private static let dbSessionID = "persistent"
    private static let dbFormKey = "searchFormFields"

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
            let w = hit.work
            if !(ci(w.title, text) || w.authors.contains { ci($0, text) } || ci(w.summary, text)) {
                return false
            }
        }
        if !Self.numberMatches(f.kudos, value: UInt64(hit.work.kudos)) { return false }
        if !Self.numberMatches(f.words, value: hit.work.wordCount) { return false }
        if !f.tags.isEmpty {
            let all = hit.work.relationships + hit.work.characters + hit.work.tags + hit.tags
            for tag in f.tags
            where !all.contains(where: { $0.caseInsensitiveCompare(tag) == .orderedSame }) {
                return false
            }
        }
        for fandom in f.fandoms
        where !hit.work.fandoms.contains(where: { $0.caseInsensitiveCompare(fandom) == .orderedSame }) {
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
        Set(bookmarkHits.flatMap { $0.work.relationships + $0.work.characters + $0.work.tags + $0.tags })
            .sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
    }

    var bookmarkFilterFandomPool: [String] {
        Set(bookmarkHits.flatMap(\.work.fandoms))
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
    private var originScope: SearchScope?

    // MARK: - Split collection results (works | bookmarks, side by side)

    /// Non-nil while a collection with both works and bookmarked items is
    /// open from the search results: the results area splits into a works
    /// pane (the shared works-results state) and a bookmarks pane (the
    /// bookmark* state below), each paged independently.
    var splitCollectionName: String?
    var splitCollectionTitle: String?
    /// What the collections results list was showing, restored when the
    /// split closes so its pager keeps working.
    private var splitReturnQuery: ActiveQuery?

    /// Set while a single-pane collection drill-in was opened from the
    /// collections hit list: the results back arrow pops back to that
    /// list (splitReturnQuery's counterpart for the no-split case) before
    /// a second press reaches the form.
    private(set) var canReturnToCollectionHits = false
    /// The hit list's query, restored on that pop so its pager keeps
    /// working (nil for library hit lists, whose pager is inert).
    private var collectionReturnQuery: ActiveQuery?

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
        guard let json = appState.bridge.getSessionCache(key: Self.dbFormKey, sessionId: Self.dbSessionID),
              let fields = Self.decodeForm(json), !fields.isEmpty else { return false }
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
            if let json = Self.encodeForm(fields) {
                appState.bridge.setSessionCache(key: Self.dbFormKey, data: json, sessionId: Self.dbSessionID)
            }
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

    @MainActor
    private func beginNewQuery(_ appState: AppState) {
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
        case (.works, false):
            performSearch(appState)
        case (.works, true):
            runLibraryWorksSearch(appState, criteria: libraryCriteria())
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

    /// The current works-form state as label-based criteria for the local
    /// library search. Select and checkbox choices are stored as AO3's
    /// option values (numeric ids); the scraped form knows each value's
    /// label, and the core matches on names — translate here so the Rust
    /// side never needs AO3's id tables.
    @MainActor
    func libraryCriteria() -> ULibrarySearchCriteria {
        var c = Self.emptyLibraryCriteria()
        // Works even when the criteria form was never scraped.
        c.query = queryText
        for field in formFields {
            let name = field.name
            let value = (fieldValues[name] ?? "").trimmingCharacters(in: .whitespaces)
            let checked = checkboxValues[name] ?? []
            // Selected option values → their labels, for id-valued controls.
            func labels() -> [String] {
                let values = checked.isEmpty ? (value.isEmpty ? [] : [value]) : Array(checked)
                return values.compactMap { v in
                    field.options.first { $0.value == v }?.label
                        .trimmingCharacters(in: .whitespaces)
                }.filter { !$0.isEmpty }
            }
            if name.hasSuffix("[title]") { c.title = value }
            else if name.hasSuffix("[creators]") { c.creators = value }
            else if name.hasSuffix("[revised_at]") { c.revisedAt = value }
            else if name.hasSuffix("[complete]") { c.complete = value }
            else if name.hasSuffix("[crossover]") { c.crossover = value }
            else if name.hasSuffix("[single_chapter]") { c.singleChapter = checked.contains("1") || value == "1" }
            else if name.hasSuffix("[word_count]") { c.wordCount = value }
            else if name.hasSuffix("[language_id]") { c.language = labels().first ?? "" }
            else if name.hasSuffix("[fandom_names]") { c.fandomNames = value }
            else if name.hasSuffix("[character_names]") { c.characterNames = value }
            else if name.hasSuffix("[relationship_names]") { c.relationshipNames = value }
            else if name.hasSuffix("[freeform_names]") { c.freeformNames = value }
            else if name.contains("[rating_ids]") { c.ratings = labels() }
            else if name.contains("[archive_warning_ids]") { c.warnings = labels() }
            else if name.contains("[category_ids]") { c.categories = labels() }
            else if name.hasSuffix("[hits]") { c.hits = value }
            else if name.hasSuffix("[kudos_count]") { c.kudosCount = value }
            else if name.hasSuffix("[comments_count]") { c.commentsCount = value }
            else if name.hasSuffix("[bookmarks_count]") { c.bookmarksCount = value }
            else if name.hasSuffix("[sort_column]") { c.sortColumn = value }
            else if name.hasSuffix("[sort_direction]") { c.sortDirection = value }
        }
        return c
    }

    /// Library mode for Works: evaluate the form's criteria against the
    /// cached works and reuse the works results pane. No pagination — the
    /// library returns everything at once (activeQuery stays nil so the
    /// pager stays inert).
    @MainActor
    private func runLibraryWorksSearch(_ appState: AppState, criteria: ULibrarySearchCriteria) {
        presentLibraryWorks(
            appState.bridge.searchLibraryWorksFiltered(criteria).map(AppState.workFromSummary),
            appState: appState)
    }

    /// Land a library (no-network) result set in the works results pane.
    /// activeQuery stays nil so the pager stays inert — library reads
    /// return everything at once.
    @MainActor
    private func presentLibraryWorks(_ works: [Work], appState: AppState) {
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
    private func beginLibraryScopeResults(_ appState: AppState) {
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

    @MainActor
    func performSearch(_ appState: AppState) {
        var keys: [String] = []
        var values: [String] = []
        for (name, value) in fieldValues where !value.isEmpty {
            keys.append(name)
            values.append(value)
        }
        for (name, selected) in checkboxValues {
            for value in selected {
                keys.append(name)
                values.append(value)
            }
        }
        activeQuery = .form(keys: keys, values: values)
        beginNewQuery(appState)
        Task { await fetch(page: 1, appState: appState) }
    }

    @MainActor
    func startTagQuery(_ tag: String, appState: AppState) {
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
            let bookmarks = appState.bridge.getLibraryCollectionBookmarks(name: name)
                .map(AppState.workFromSummary)
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

    @MainActor
    private func fetchBookmarksPage(_ page: UInt32, appState: AppState) async {
        guard let name = splitCollectionName else { return }
        isFetchingBookmarks = true
        bookmarksError = nil
        do {
            let result = try await appState.retryOnTimeout(task: appState.searchTask, using: appState.bridge) {
                try await appState.bridge.fetchCollectionBookmarks(name: name, page: page)
            }
            bookmarkResults = result.works.map(AppState.workFromSummary)
            bookmarksPage = page
            bookmarksHasNext = result.hasNextPage
            bookmarksTotalPages = max(result.totalPages, page)
            bookmarksTotal = result.totalWorks
            // Fetched works are persisted by the Rust layer — refresh the
            // library snapshot so they join local lists at once.
            appState.reloadCachedWorks()
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
    private func fetch(page: UInt32, appState: AppState) async {
        guard let query = activeQuery else { return }
        hasSearched = true
        appState.isSearching = true
        appState.searchError = nil
        do {
            switch query {
            case .form(let keys, let values):
                applyWorksPage(try await appState.retryOnTimeout(task: appState.searchTask, using: appState.bridge) {
                    try await appState.bridge.searchWorksRawPaged(keys: keys, values: values, page: page)
                }, page: page, appState: appState)
            case .tag(let tag):
                applyWorksPage(try await appState.retryOnTimeout(task: appState.searchTask, using: appState.bridge) {
                    try await appState.bridge.searchByTagPaged(tag, page: page)
                }, page: page, appState: appState)
            case .collection(let name):
                applyWorksPage(try await appState.retryOnTimeout(task: appState.searchTask, using: appState.bridge) {
                    try await appState.bridge.fetchCollectionWorks(name: name, page: page)
                }, page: page, appState: appState)
            case .collectionBookmarks(let name):
                applyWorksPage(try await appState.retryOnTimeout(task: appState.searchTask, using: appState.bridge) {
                    try await appState.bridge.fetchCollectionBookmarks(name: name, page: page)
                }, page: page, appState: appState)
            case .bookmarkSearch(let criteria):
                let result = try await appState.retryOnTimeout(task: appState.searchTask, using: appState.bridge) {
                    try await appState.bridge.searchBookmarks(criteria: criteria, page: page)
                }
                bookmarkHits = result.bookmarks
                totalWorks = result.totalFound
                currentPage = page
                hasNextPage = result.hasNextPage
                totalPages = max(result.totalPages, page)
                // Fetched works are persisted by the Rust layer — refresh
                // the library snapshot so they join local lists at once.
                appState.reloadCachedWorks()
            case .collectionsIndex(let criteria):
                let result = try await appState.retryOnTimeout(task: appState.searchTask, using: appState.bridge) {
                    try await appState.bridge.browseCollections(criteria: criteria, page: page)
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
        // refresh the library snapshot so they join local lists at once.
        appState.reloadCachedWorks()
    }

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

    func loadSavedSearches(_ appState: AppState) {
        savedSearches = appState.bridge.getSavedSearches()
    }

    /// Persist the current criteria (query, fields, checkboxes) under a name.
    func saveCurrentSearch(named name: String, appState: AppState) {
        NSLog("[saved-search] saveCurrentSearch(%@): %d field(s), %d checkbox group(s)",
              name, fieldValues.count, checkboxValues.count)
        let payload: [String: Any] = [
            "fieldValues": fieldValues,
            "checkboxValues": checkboxValues.mapValues { Array($0) },
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: payload),
              let json = String(data: data, encoding: .utf8) else {
            NSLog("[saved-search] saveCurrentSearch(%@): JSON encode failed", name)
            return
        }
        appState.bridge.saveSearch(name: name, paramsJson: json)
        loadSavedSearches(appState)
    }

    /// Restore a saved search's criteria into the form (query, fields,
    /// checkboxes) so the user can tweak them before running the search.
    @MainActor
    func applySavedSearch(_ saved: USavedSearch) {
        guard let data = saved.paramsJson.data(using: .utf8),
              let payload = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
        fieldValues = payload["fieldValues"] as? [String: String] ?? [:]
        let boxes = payload["checkboxValues"] as? [String: [String]] ?? [:]
        checkboxValues = boxes.mapValues(Set.init)
    }

    func deleteSavedSearch(_ id: Int64, appState: AppState) {
        appState.bridge.deleteSavedSearch(id)
        loadSavedSearches(appState)
    }

    /// One-line criteria summary for a saved-search row: the query text plus
    /// how many other criteria are set — so same-named searches are tellable
    /// apart without running them.
    static func summary(of saved: USavedSearch) -> String? {
        guard let data = saved.paramsJson.data(using: .utf8),
              let payload = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        let fields = payload["fieldValues"] as? [String: String] ?? [:]
        let boxes = payload["checkboxValues"] as? [String: [String]] ?? [:]
        let query = fields.first { $0.key.hasSuffix("[query]") && !$0.value.isEmpty }?.value
        let filterCount = fields.filter { !$0.key.hasSuffix("[query]") && !$0.value.isEmpty }.count
            + boxes.reduce(0) { $0 + $1.value.count }
        var parts: [String] = []
        if let query { parts.append("“\(query)”") }
        if filterCount > 0 {
            parts.append(filterCount == 1 ? "1 filter" : "\(filterCount) filters")
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    // MARK: - Form JSON (same shape the iOS cache uses)

    private static func encodeForm(_ fields: [UFormField]) -> String? {
        let data: [[String: Any]] = fields.map { f in
            [
                "name": f.name, "label": f.label, "fieldType": f.fieldType,
                "placeholder": f.placeholder,
                "options": f.options.map { ["value": $0.value, "label": $0.label, "selected": $0.selected] },
            ]
        }
        guard let json = try? JSONSerialization.data(withJSONObject: data) else { return nil }
        return String(data: json, encoding: .utf8)
    }

    private static func decodeForm(_ json: String) -> [UFormField]? {
        guard let data = json.data(using: .utf8),
              let arr = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { return nil }
        let fields = arr.compactMap { dict -> UFormField? in
            guard let name = dict["name"] as? String,
                  let label = dict["label"] as? String,
                  let fieldType = dict["fieldType"] as? String,
                  let placeholder = dict["placeholder"] as? String,
                  let optArr = dict["options"] as? [[String: Any]] else { return nil }
            let options = optArr.compactMap { o -> UFormOption? in
                guard let value = o["value"] as? String,
                      let label = o["label"] as? String,
                      let selected = o["selected"] as? Bool else { return nil }
                return UFormOption(value: value, label: label, selected: selected)
            }
            return UFormField(name: name, label: label, fieldType: fieldType, placeholder: placeholder, options: options)
        }
        return fields.isEmpty ? nil : fields
    }
}
