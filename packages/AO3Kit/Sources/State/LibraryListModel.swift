import Foundation
import Observation

/// Sort, filter and ordering for every work list in the library. Persisted
/// per-section preferences (sort, completion, rating) live in the encrypted
/// DB; session list filters live here and are scoped to the list they were
/// set on. The list's membership (which works) is the caller's — each
/// platform model knows its drill-in state — so the entry points take the
/// raw works and return them filtered and ordered by the Rust engine.
@Observable
@MainActor
final class LibraryListModel {
    typealias Section = LibrarySection

    let appState: AppState

    init(appState: AppState) {
        self.appState = appState
    }

    // MARK: - Sorting & filtering

    enum WorkSort: String, CaseIterable {
        case natural, updated, kudos, words, title

        var label: String {
            switch self {
            case .natural: "Default Order"
            case .updated: "Recently Updated"
            case .kudos: "Most Kudos"
            case .words: "Longest"
            case .title: "Title A–Z"
            }
        }
    }

    enum CompletionFilter: String, CaseIterable {
        case all, complete, inProgress

        var label: String {
            switch self {
            case .all: "All Works"
            case .complete: "Complete Only"
            case .inProgress: "In Progress Only"
            }
        }
    }

    /// Per-section sort/filter choices — durable in the encrypted DB (pref
    /// keys "workSort.<section>" etc.), cached here for synchronous reads.
    /// Loaded by loadPersistedPrefs() once the DB is unlocked.
    private var workSorts: [String: String] = [:]
    private var completionFilters: [String: String] = [:]
    private var ratingFilters: [String: String] = [:]

    func workSort(for section: Section) -> WorkSort {
        WorkSort(rawValue: workSorts[String(describing: section)] ?? "") ?? .natural
    }

    func setWorkSort(_ sort: WorkSort, for section: Section) {
        workSorts[String(describing: section)] = sort.rawValue
        appState.bridge.setPref(key: "workSort.\(section)", value: sort.rawValue)
    }

    func completionFilter(for section: Section) -> CompletionFilter {
        CompletionFilter(rawValue: completionFilters[String(describing: section)] ?? "") ?? .all
    }

    func setCompletionFilter(_ filter: CompletionFilter, for section: Section) {
        completionFilters[String(describing: section)] = filter.rawValue
        appState.bridge.setPref(key: "completionFilter.\(section)", value: filter.rawValue)
    }

    func ratingFilter(for section: Section) -> Rating? {
        ratingFilters[String(describing: section)].flatMap(Rating.init(rawValue:))
    }

    func setRatingFilter(_ rating: Rating?, for section: Section) {
        // "" = All (Rating(rawValue: "") is nil, same as no entry).
        ratingFilters[String(describing: section)] = rating?.rawValue ?? ""
        appState.bridge.setPref(key: "ratingFilter.\(section)", value: rating?.rawValue ?? "")
    }

    /// Whether a list filter outlives the list it was set on. Off (the
    /// default) makes a filter belong to its list: close an author's works,
    /// pick a different fandom, run a new search, and the filter clears so
    /// the next list opens whole. On makes filters standing preferences that
    /// carry from list to list until cleared by hand. One app-wide choice,
    /// durable in the encrypted DB.
    private(set) var retainListFilters = false

    func setRetainListFilters(_ retain: Bool) {
        retainListFilters = retain
        appState.bridge.setPref(key: "retainListFilters", value: retain ? "1" : "0")
    }

    private var prefsLoaded = false

    /// Load prefs from the Rust core (migrating any pre-DB UserDefaults
    /// values into it, once). Called after the encrypted DB unlocks,
    /// alongside AppState.loadPersistedState().
    func loadPersistedPrefs() {
        guard !prefsLoaded, appState.bridge.isDatabaseOpen else { return }
        prefsLoaded = true
        migrateUserDefaultsPrefs()
        let bridge = appState.bridge
        for s in Section.allCases {
            let name = String(describing: s)
            if let v = bridge.getPref(key: "workSort.\(name)") { workSorts[name] = v }
            if let v = bridge.getPref(key: "completionFilter.\(name)") { completionFilters[name] = v }
            if let v = bridge.getPref(key: "ratingFilter.\(name)") { ratingFilters[name] = v }
        }
        retainListFilters = bridge.getPref(key: "retainListFilters") == "1"
    }

    /// One-time move of prefs out of UserDefaults into the encrypted DB.
    /// The legacy global completion/rating filters seed every section that
    /// never made a per-section choice; every old key vanishes.
    private func migrateUserDefaultsPrefs() {
        let defaults = UserDefaults.standard
        let bridge = appState.bridge
        let dictKeys = [("workSorts", "workSort"),
                        ("completionFilters", "completionFilter"),
                        ("ratingFilters", "ratingFilter")]
        for (defaultsKey, prefPrefix) in dictKeys {
            if let dict = defaults.dictionary(forKey: defaultsKey) as? [String: String] {
                for (section, v) in dict { bridge.setPref(key: "\(prefPrefix).\(section)", value: v) }
                defaults.removeObject(forKey: defaultsKey)
            }
        }
        for (legacyKey, prefPrefix) in [("completionFilter", "completionFilter"),
                                        ("ratingFilter", "ratingFilter")] {
            if let legacy = defaults.string(forKey: legacyKey) {
                for s in Section.allCases where bridge.getPref(key: "\(prefPrefix).\(s)") == nil {
                    bridge.setPref(key: "\(prefPrefix).\(s)", value: legacy)
                }
                defaults.removeObject(forKey: legacyKey)
            }
        }
    }

    // MARK: - Ordering

    /// A section's list: the raw membership run through the Rust engine
    /// with the section's persisted prefs and session filter; What's New
    /// additionally keeps unopened entries on top.
    func works(for section: Section, raw: [Work]) -> [Work] {
        let sorted = filterAndSort(raw,
                                   query: query(for: section, sectionFilters: true, listFilter: true,
                                                sort: workSort(for: section)),
                                   section: section)
        return section == .whatsNew ? whatsNewPinnedFirst(sorted) : sorted
    }

    /// A drill-in list that applies only the session list filter — no
    /// section prefs, natural order (the fandom drill-in).
    func listFiltered(_ raw: [Work], section: Section) -> [Work] {
        filterAndSort(raw,
                      query: query(for: section, sectionFilters: false, listFilter: true, sort: .natural),
                      section: section)
    }

    // MARK: - What's New: unopened entries first

    /// Entries held above the rest of the What's New list: the ones unseen
    /// when the section was entered, plus any that arrive from a check
    /// while it's showing. Frozen per visit so selecting a row (which
    /// marks it seen and drops its badge) doesn't yank it down the list
    /// under the pointer; the next visit re-sorts. Bookkeeping, not render
    /// state.
    @ObservationIgnored private var whatsNewPinned: Set<String> = []
    @ObservationIgnored private var whatsNewPinnedForIDs: [String]?

    /// Call when the What's New list is entered: the next evaluation pins
    /// exactly the entries unseen at that moment.
    func resetWhatsNewPins() {
        whatsNewPinnedForIDs = nil
    }

    /// Stable partition: pinned entries first, each group keeping the
    /// user's chosen sort order.
    private func whatsNewPinnedFirst(_ works: [Work]) -> [Work] {
        let ids = appState.newWorkIDs
        if whatsNewPinnedForIDs != ids {
            // First evaluation of a visit: exactly the unseen entries. A
            // later membership change (a check landed) adds its unseen
            // arrivals and keeps what was already pinned.
            let unseen = appState.unseenNewWorkIDs
            whatsNewPinned = whatsNewPinnedForIDs == nil
                ? unseen.intersection(ids)
                : whatsNewPinned.union(unseen).intersection(ids)
            whatsNewPinnedForIDs = ids
        }
        guard !whatsNewPinned.isEmpty else { return works }
        return works.filter { whatsNewPinned.contains($0.id) }
            + works.filter { !whatsNewPinned.contains($0.id) }
    }

    // MARK: - Filter/sort compute (delegated to the Rust core)

    /// Assemble the Rust-side query for a section from its persisted
    /// sort/filter prefs and (optionally) its session list filter.
    private func query(for section: Section, sectionFilters: Bool, listFilter: Bool,
                       sort: WorkSort) -> UWorkListQuery {
        let f = listFilter ? workListFilter(for: section) : WorkListFilter()
        return UWorkListQuery(
            sort: sort.rawValue,
            completion: sectionFilters ? completionFilter(for: section).rawValue
                                       : CompletionFilter.all.rawValue,
            rating: sectionFilters ? ratingFilter(for: section)?.rawValue : nil,
            hideExplicit: sectionFilters && appState.hideExplicit,
            text: f.text,
            kudosExpr: f.kudos,
            wordsExpr: f.words,
            tags: Array(f.tags),
            fandoms: Array(f.fandoms))
    }

    /// Run a work list through the Rust core's filter/sort engine. Sample
    /// works use slug ids and exist only in Swift memory — they can't
    /// round-trip through the works cache, so sample-mode lists pass through
    /// unmodified.
    ///
    /// Several views evaluate the same list per render pass (a toolbar's
    /// count, the table's rows), and the engine re-reads the works from the
    /// DB on every call — so the ordering is memoized per section. An entry
    /// stays valid until the section's ids or query change or work metadata
    /// lands (worksGeneration): the engine's inputs are exactly
    /// (membership, criteria, cached metadata), so nothing else —
    /// reading-progress writes included — can change its answer.
    /// @ObservationIgnored: the memo is bookkeeping, not render state — if
    /// observation tracked it, each store would re-trigger the renders it
    /// exists to deduplicate.
    @ObservationIgnored
    private var filterSortMemo: [Section: (ids: [UInt64], query: UWorkListQuery,
                                           generation: UInt64, ordered: [UInt64])] = [:]

    private func filterAndSort(_ works: [Work], query: UWorkListQuery, section: Section) -> [Work] {
        let ids = works.compactMap { UInt64($0.id) }
        guard ids.count == works.count else { return works }
        let ordered: [UInt64]
        if let memo = filterSortMemo[section], memo.ids == ids, memo.query == query,
           memo.generation == appState.worksGeneration {
            ordered = memo.ordered
        } else {
            ordered = appState.bridge.filterAndSortWorks(ids: ids, query: query)
            filterSortMemo[section] = (ids, query, appState.worksGeneration, ordered)
        }
        let byID = Dictionary(works.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        return ordered.compactMap { byID[String($0)] }
    }

    // MARK: - List filters (session-scoped, tailored per content type)

    struct WorkListFilter {
        var text = ""
        /// Numeric filters accepting ">" / "<" prefixes (plain number = at least).
        var kudos = ""
        var words = ""
        var tags: Set<String> = []
        var fandoms: Set<String> = []
        var isActive: Bool {
            !text.trimmingCharacters(in: .whitespaces).isEmpty
                || !kudos.trimmingCharacters(in: .whitespaces).isEmpty
                || !words.trimmingCharacters(in: .whitespaces).isEmpty
                || !tags.isEmpty
                || !fandoms.isEmpty
        }
    }

    /// Per-section work-list filter (text over title/author/summary + tag toggles).
    var workListFilters: [Section: WorkListFilter] = [:]
    /// Following list: subscription name.
    var subscriptionListFilter = ""
    /// Authors list: username.
    var authorsListFilter = ""
    /// Authors list source filters (header popover checkboxes).
    var authorsIncludeFollowed = true
    var authorsIncludeSubscribed = true
    /// Whether the "Follow an author" input is showing (header + button).
    var showFollowAuthorField = false
    /// Fandoms list: fandom name.
    var fandomsListFilter = ""
    /// Inbox: three targeted fields.
    var inboxFilterAuthor = ""
    var inboxFilterWork = ""
    var inboxFilterText = ""

    func workListFilter(for s: Section) -> WorkListFilter {
        workListFilters[s] ?? WorkListFilter()
    }

    /// The app-wide filter rule. A list filter is scoped to the list it was
    /// set on, so whenever one of these lists is torn down or swapped for a
    /// different target — another author, another fandom, a new search — the
    /// filter that targeted it is dropped and the incoming list shows whole.
    /// `retainListFilters` opts out, keeping filters across lists instead.
    /// Every list that can be emptied or re-targeted calls this; lists that
    /// are always the same list (History, Bookmarks, Downloads, What's New)
    /// never do, so their filters stand until the user clears them.
    func listEmptied(_ sections: Section...) {
        guard !retainListFilters else { return }
        for section in sections { workListFilters[section] = nil }
    }

    /// Distinct tags across a section's (pre-list-filter) work list,
    /// alphabetically — the suggestion pool for the filter dialog.
    func availableTags(for s: Section, raw: [Work]) -> [String] {
        filterOptions(for: s, raw: raw).tags
    }

    /// Distinct fandoms across a section's (pre-list-filter) work list — the
    /// suggestion pool for the filter dialog's fandom field.
    func availableFandoms(for s: Section, raw: [Work]) -> [String] {
        filterOptions(for: s, raw: raw).fandoms
    }

    private func filterOptions(for s: Section, raw: [Work]) -> UWorkFilterOptions {
        let ids = raw.compactMap { UInt64($0.id) }
        guard ids.count == raw.count else {
            // Sample-mode lists never reach the works cache — offer their
            // tags/fandoms directly.
            let tags = Set(raw.flatMap(\.tags))
            let fandoms = Set(raw.flatMap { $0.fandoms.isEmpty ? [$0.fandom] : $0.fandoms })
            return UWorkFilterOptions(
                tags: tags.sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending },
                fandoms: fandoms.sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending })
        }
        return appState.bridge.workFilterOptions(
            ids: ids,
            query: query(for: s, sectionFilters: true, listFilter: false, sort: .natural))
    }

    var filteredSubscriptions: [USubscription] {
        let needle = subscriptionListFilter.trimmingCharacters(in: .whitespaces).lowercased()
        guard !needle.isEmpty else { return appState.subscriptions }
        return appState.subscriptions.filter { $0.name.lowercased().contains(needle) }
    }

    var filteredInboxMessages: [InboxItem] {
        let author = inboxFilterAuthor.trimmingCharacters(in: .whitespaces).lowercased()
        let work = inboxFilterWork.trimmingCharacters(in: .whitespaces).lowercased()
        let text = inboxFilterText.trimmingCharacters(in: .whitespaces).lowercased()
        guard !author.isEmpty || !work.isEmpty || !text.isEmpty else { return appState.inboxMessages }
        return appState.inboxMessages.filter { item in
            (author.isEmpty || item.author.lowercased().contains(author))
                && (work.isEmpty || item.workReference.lowercased().contains(work))
                && (text.isEmpty || item.contentJson.lowercased().contains(text))
        }
    }
}
