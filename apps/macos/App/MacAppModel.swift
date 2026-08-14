import Foundation
import Observation

/// Navigation + selection state for the three-pane reader. Pure UI state —
/// all library data, network fetching, and persistence live in the shared
/// AppState/RustBridge, exactly as on iOS.
@Observable
final class MacAppModel {
    enum Section: String, CaseIterable {
        case browse, reading, history, subscriptions, whatsNew, inbox, fandoms, authors,
             bookmarks, downloads, stats, search, authorWorks, readingLists, collections,
             settings
    }

    let appState: AppState
    let search: MacSearchModel

    /// The app opens on Currently Reading — the primary use case.
    var section: Section = .reading
    var selectedWorkID: String?
    var readerOpen = false
    var readerChapter = 0
    var immersive = false
    var query = ""
    /// Reading list shown in the list pane when a collection is selected.
    var selectedReadingListID: Int64?
    /// Title override for search results driven from elsewhere (fandom cards).
    var searchDisplayTitle: String?

    init(appState: AppState) {
        self.appState = appState
        self.search = MacSearchModel()
        // A new query throws away the previous results, so the filter that
        // targeted them goes too — the same rule every other list follows.
        search.onNewQuery = { [weak self] in self?.listEmptied(.search) }
    }

    var selectedWork: Work? {
        selectedWorkID.flatMap { appState.work(byID: $0) }
    }

    /// Everything the app is fetching right now, for summarized loading
    /// feedback. Combines shared AppState flags with Mac-local operations.
    var inFlightOperations: [String] {
        var ops: [String] = []
        if let recovery = appState.currentRecovery { ops.append(Self.recoveryStatusText(recovery)) }
        if appState.isTestingCircuit { ops.append("Testing Tor circuit \(appState.circuitAttempt)") }
        if appState.isResolvingCloudflare { ops.append("Clearing archive challenge") }
        if appState.isBrowsing { ops.append("Loading newest works") }
        if appState.isSearching { ops.append("Searching the archive") }
        if appState.isLoadingSubscriptions { ops.append("Loading your subscription list") }
        if appState.isCheckingSubscriptions {
            let done = appState.subscriptionCheckTotal - appState.subscriptionCheckRemaining
            if appState.subscriptionCheckTotal > 0 {
                ops.append("Checking subscriptions (\(done)/\(appState.subscriptionCheckTotal))")
            } else {
                ops.append("Checking subscriptions")
            }
        }
        if isLoadingSubscriptionWorks { ops.append("Fetching \(subscriptionWorksTitle ?? "author")’s works") }
        if isLoadingAuthor { ops.append("Fetching \(authorUsername ?? "author")’s works") }
        if isLoadingCollections { ops.append("Loading collections") }
        if search.isLoadingForm { ops.append("Loading search criteria") }
        if let sync = appState.bookmarkSyncTask.statusMessage { ops.append(sync) }
        return ops
    }

    /// Names the recovery engine's remedy honestly — mirrors iOS's
    /// NetworkLoadingView.recoveryMessage. macOS previously showed nothing
    /// at all during a stall like this; now the status bar does.
    static func recoveryStatusText(_ recovery: AppState.RecoveryStatus) -> String {
        let attempt = "(\(recovery.attempt) of \(recovery.maxAttempts))"
        switch recovery.step {
        case .earningClearance:
            return "Passing the archive's connection check… \(attempt)"
        case .backingOff(let seconds):
            return "Archive temporarily unavailable — waiting \(seconds)s… \(attempt)"
        case .rotatingCircuit, .retrying, nil:
            break
        }
        switch recovery.remedy {
        case .rotate, .rotateAndReclear:
            return "Archive connection failed — trying a new route… \(attempt)"
        case .backoff:
            return "Archive temporarily unavailable — retrying… \(attempt)"
        case .purge:
            return "Session expired — please sign in again"
        }
    }

    var hideExplicit: Bool {
        get { appState.hideExplicit }
        set { appState.hideExplicit = newValue }
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

    /// Load prefs + follows from the Rust core (migrating any pre-DB
    /// UserDefaults values into it, once). Called after the encrypted DB
    /// unlocks, alongside AppState.loadPersistedState().
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
        followedFandoms = bridge.getFollowed(kind: "fandom")
        followedAuthorNames = bridge.getFollowed(kind: "author")
    }

    /// One-time move of prefs and follows out of UserDefaults into the
    /// encrypted DB. The legacy global completion/rating filters seed every
    /// section that never made a per-section choice; every old key vanishes.
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
        for (defaultsKey, kind) in [("followedFandoms", "fandom"), ("followedAuthors", "author")] {
            if let names = defaults.stringArray(forKey: defaultsKey) {
                for name in names { bridge.addFollowed(kind: kind, name: name) }
                defaults.removeObject(forKey: defaultsKey)
            }
        }
    }

    // MARK: - Intents

    // MARK: - Per-section pane memory (session-scoped, never persisted)

    /// What the reading pane was showing for a section — restored when the
    /// user returns to it. Held in memory only, by design: gone on relaunch.
    private struct PaneSnapshot {
        var selectedWorkID: String?
        var readerOpen = false
        var readerChapter = 0
        var selectedReadingListID: Int64?
    }

    private var paneSnapshots: [Section: PaneSnapshot] = [:]

    private func snapshotPane(for s: Section) {
        paneSnapshots[s] = PaneSnapshot(
            selectedWorkID: selectedWorkID,
            readerOpen: readerOpen,
            readerChapter: readerChapter,
            selectedReadingListID: selectedReadingListID)
    }

    private func restorePane(for s: Section) {
        let snap = paneSnapshots[s] ?? PaneSnapshot()
        immersive = false
        selectedReadingListID = snap.selectedReadingListID
        selectedWorkID = snap.selectedWorkID
        readerChapter = snap.readerChapter
        if snap.readerOpen, let id = snap.selectedWorkID {
            // Reopening the reader lands where it was — stash the saved
            // position exactly like openReader does.
            if let progress = appState.progressMap[id], progress.chapter == snap.readerChapter + 1 {
                readerResumePos = progress.pos
            } else {
                readerResumePos = 0
            }
            readerOpen = true
        } else {
            readerOpen = false
        }
    }

    func goSection(_ s: Section) {
        guard s != section else { return }
        // Remember what this section's pane was showing; restore the target's.
        // Drill-in state (author/subscription works lists, inbox selection)
        // is deliberately left alive — it only renders in its own section,
        // and in-flight crawls keep their bookkeeping.
        snapshotPane(for: section)
        // Leaving the work (even to another section) drops the return point.
        readerReturnPoint = nil
        section = s
        restorePane(for: s)
        switch s {
        case .browse:
            if appState.browseResults.isEmpty {
                Task { await appState.browseLatestWorks() }
            }
        case .search:
            Task { await search.loadFormIfNeeded(appState) }
        case .subscriptions:
            Task { await appState.loadSubscriptions() }
        case .whatsNew:
            appState.loadNotifications()
        case .inbox:
            appState.loadCachedInbox()
            Task { await appState.checkInbox() }
        case .collections:
            if collections.isEmpty {
                loadMoreCollections()
            }
        default:
            break
        }
    }

    /// Open a reading list's works in the reading pane (the Reading Lists
    /// section's drill-in, mirroring the Subscriptions → works flow).
    func goReadingList(_ listID: Int64) {
        goSection(.readingLists)
        if selectedReadingListID != listID { listEmptied(.readingLists) }
        selectedReadingListID = listID
        selectedWorkID = nil
        readerOpen = false
    }

    /// Close the drill-in: back to "select a list".
    func closeReadingList() {
        listEmptied(.readingLists)
        selectedReadingListID = nil
        selectedWorkID = nil
        readerOpen = false
    }

    var filteredReadingListWorks: [Work] {
        works(for: .readingLists)
    }

    /// Route an archiveofourown.org link to the matching screen.
    /// Returns false when the URL isn't something the app can open (yet).
    @discardableResult
    func openAO3URL(_ raw: String) -> Bool {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        let candidate = trimmed.hasPrefix("http") ? trimmed : "https://\(trimmed)"
        guard let url = URL(string: candidate) else { return false }
        if let host = url.host, !host.hasSuffix("archiveofourown.org") { return false }
        let parts = url.path.split(separator: "/").map(String.init)

        if let i = parts.firstIndex(of: "works"), i + 1 < parts.count, UInt64(parts[i + 1]) != nil {
            openWorkByID(parts[i + 1])
            return true
        }
        if let i = parts.firstIndex(of: "users"), i + 1 < parts.count, !parts[i + 1].isEmpty {
            goSection(.authors)
            openAuthor(parts[i + 1])
            return true
        }
        if let i = parts.firstIndex(of: "series"), i + 1 < parts.count, UInt64(parts[i + 1]) != nil {
            goSection(.subscriptions)
            openSubscriptionAuthorWorks(subscriptionID: parts[i + 1],
                                        author: "Series \(parts[i + 1])",
                                        subType: "series")
            return true
        }
        return false
    }

    /// Show a work's detail page, fetching its metadata first when it isn't
    /// known locally (e.g. opened from a pasted URL).
    func openWorkByID(_ id: String) {
        if appState.work(byID: id) != nil {
            selectWork(id)
            return
        }
        Task { @MainActor in
            await appState.fetchWorkMetadata(id)
            if appState.work(byID: id) != nil {
                selectWork(id)
            }
        }
    }

    /// Jump from the end of a work straight into the next work of its
    /// series, fetching metadata first when it isn't known locally.
    func openNextWorkInSeries(_ id: String) {
        Task { @MainActor in
            if appState.work(byID: id) == nil {
                await appState.fetchWorkMetadata(id)
            }
            // Restricted/deleted next work: stay where we are.
            guard appState.work(byID: id) != nil else { return }
            selectWork(id)
            openReader(id, chapter: 0)
        }
    }

    /// Escape: close the innermost open context.
    /// Returns false when there was nothing left to close.
    @discardableResult
    func escapeInnermost() -> Bool {
        if immersive {
            immersive = false
            return true
        }
        if readerOpen {
            closeReader()
            return true
        }
        if selectedWorkID != nil {
            clearSelection()
            return true
        }
        if section == .subscriptions && subscriptionWorksTitle != nil {
            closeSubscriptionWorks()
            return true
        }
        if section == .authors && authorUsername != nil {
            closeAuthorWorks()
            return true
        }
        if section == .fandoms && fandomWorksTag != nil {
            closeFandomWorks()
            return true
        }
        if section == .collections && collectionWorksName != nil {
            closeCollectionWorks()
            return true
        }
        return false
    }

    func selectWork(_ id: String) {
        if selectedWorkID != id { selectedWorkID = id }
        if readerOpen { readerOpen = false }
        readerReturnPoint = nil
        // Opening the detail view counts as "seen" for the What's New badge.
        appState.markDetailViewed(id)
        // Fill in full metadata (tags, summary, chapter titles) if the row
        // came from a listing with partial data.
        Task { await appState.fetchWorkMetadata(id) }
    }

    func openReader(_ id: String, chapter: Int, at pos: Int? = nil) {
        // A chapter change within the open work remembers where the reader
        // was, so the footer's return control can take them back. A fresh
        // open starts with no return point — only this chapter has been seen.
        if readerOpen && selectedWorkID == id {
            if chapter != readerChapter {
                let stored = appState.progressMap[id]
                stashReturnPoint(chapter: readerChapter,
                                 pos: stored?.chapter == readerChapter + 1 ? stored?.pos ?? 0 : 0)
            }
        } else {
            readerReturnPoint = nil
        }
        // Stash the in-chapter position — the reader consumes this to land
        // back on the anchored line. An explicit `pos` (the return control)
        // wins over the saved progress.
        if let pos {
            readerResumePos = pos
        } else if let existing = appState.progressMap[id], existing.chapter == chapter + 1 {
            readerResumePos = existing.pos
        } else {
            readerResumePos = 0
        }
        aoyoPosLog("openReader work=\(id) ch=\(chapter) existing=\(appState.progressMap[id].map { "ch\($0.chapter)@\($0.pos)" } ?? "nil") stash=\(readerResumePos)")
        selectedWorkID = id
        readerChapter = chapter
        readerOpen = true
        appState.pushHistory(id)
        appState.markWorkRead(id)
        // Opening a chapter enrolls the work in Currently Reading immediately —
        // scrolling only refines the position. Re-recording the stashed
        // position keeps the saved place intact until the reader actually
        // moves; a chapter never visited starts at its top.
        appState.setProgress(id, chapter: chapter + 1, pos: readerResumePos)
    }

    /// Saved position (character offset) for the chapter being opened;
    /// consumed by the reader on its first successful render.
    var readerResumePos: Int = 0

    /// Where the reader was before the last chapter change — UI memory only,
    /// never persisted. Backs the footer's "return to previous position"
    /// control; empty on a fresh open and cleared when the work is left.
    struct ReaderReturnPoint: Equatable {
        /// 0-based chapter index.
        let chapter: Int
        /// Character offset within that chapter.
        let pos: Int
    }
    var readerReturnPoint: ReaderReturnPoint?

    func stashReturnPoint(chapter: Int, pos: Int) {
        readerReturnPoint = ReaderReturnPoint(chapter: chapter, pos: pos)
    }

    func returnToPreviousPosition() {
        guard readerOpen, let point = readerReturnPoint, let id = selectedWorkID else { return }
        // openReader stashes the chapter being left, so the control swaps
        // between the two positions rather than consuming itself.
        openReader(id, chapter: point.chapter, at: point.pos)
    }

    func closeReader() {
        readerOpen = false
        immersive = false
        readerReturnPoint = nil
    }

    /// Remove one work from Currently Reading; if it's showing in the reading
    /// pane, unload it there too.
    func removeFromCurrentlyReading(_ id: String) {
        appState.resetProgress(id)
        if selectedWorkID == id {
            clearSelection()
        }
    }

    /// Clear the whole Currently Reading list (all saved positions, including
    /// orphaned records), unloading the reading pane if it showed one of them.
    func removeAllCurrentlyReading() {
        let ids = Array(appState.progressMap.keys)
        for id in ids {
            appState.resetProgress(id)
        }
        if let selected = selectedWorkID, ids.contains(selected) {
            clearSelection()
        }
    }

    private func clearSelection() {
        selectedWorkID = nil
        readerOpen = false
        immersive = false
    }

    /// Quick search from the sidebar field: fills the criteria query and runs it.
    func submitSearch() {
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return }
        searchDisplayTitle = nil
        if section != .search {
            snapshotPane(for: section)
            section = .search
        }
        // A new search replaces the search pane's prior context by design.
        readerOpen = false
        selectedWorkID = nil
        immersive = false
        Task { @MainActor in
            await search.loadFormIfNeeded(appState)
            search.setQuery(q)
            search.performSearch(appState)
        }
    }

    /// A tag pill or fandom card: live tag-scoped results shown in Search.
    func searchTag(_ tag: String) {
        query = tag
        searchDisplayTitle = tag
        if section != .search {
            snapshotPane(for: section)
            section = .search
        }
        readerOpen = false
        selectedWorkID = nil
        immersive = false
        Task { @MainActor in
            search.startTagQuery(tag, appState: appState)
        }
    }

    /// From a work detail reached via search results: back to the results list.
    func backToResults() {
        selectedWorkID = nil
        readerOpen = false
        immersive = false
    }

    // MARK: - Followed fandoms & authors (device-local follows)

    /// User library data — lives in the encrypted Rust DB (followed_items),
    /// mirrored here for synchronous reads. Loaded by loadPersistedPrefs().
    private(set) var followedFandoms: [String] = []
    private(set) var followedAuthorNames: [String] = []

    /// Fandom drill-in: a followed fandom's works shown in the reading pane
    /// without ever leaving the Fandoms section. Local-first — opening shows
    /// the library's works for that fandom; AO3 is only searched on the
    /// explicit toolbar action.
    var fandomWorksTag: String?
    var fandomSearchActive = false

    func openFandomWorks(_ tag: String) {
        if fandomWorksTag != tag { listEmptied(.fandoms) }
        fandomWorksTag = tag
        fandomSearchActive = false
        readerOpen = false
        selectedWorkID = nil
        immersive = false
    }

    /// The explicit — and only — network trigger for the fandom drill-in:
    /// swap the pane to AO3's paged tag results.
    func searchFandomOnAO3() {
        guard let tag = fandomWorksTag else { return }
        fandomSearchActive = true
        selectedWorkID = nil
        Task { @MainActor in
            search.startTagQuery(tag, appState: appState)
        }
    }

    /// Back from AO3 results to the library view of the open fandom.
    func showFandomLibraryWorks() {
        fandomSearchActive = false
        selectedWorkID = nil
    }

    func closeFandomWorks() {
        listEmptied(.fandoms)
        fandomWorksTag = nil
        fandomSearchActive = false
        selectedWorkID = nil
    }

    /// Library works for the open fandom — matched against every fandom tag
    /// on the work (crossovers count), the same tally the Fandoms list rows
    /// show.
    var fandomLibraryWorks: [Work] {
        // List filter only — the fandom drill-in never applied the section
        // completion/rating filters or a sort.
        filterAndSort(fandomLibraryWorksRaw,
                      query: query(for: .fandoms, sectionFilters: false, listFilter: true,
                                   sort: .natural))
    }

    private var fandomLibraryWorksRaw: [Work] {
        guard let tag = fandomWorksTag else { return [] }
        return appState.cachedWorks.filter { $0.fandoms.contains(tag) || $0.fandom == tag }
    }

    func followFandom(_ name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, !followedFandoms.contains(trimmed) else { return }
        followedFandoms.append(trimmed)
        appState.bridge.addFollowed(kind: "fandom", name: trimmed)
    }

    func unfollowFandom(_ name: String) {
        followedFandoms.removeAll { $0 == name }
        appState.bridge.removeFollowed(kind: "fandom", name: name)
    }

    // MARK: - Collections browsing (AO3 /collections index)

    /// Loaded /collections index pages, accumulated. A discovery surface —
    /// never persisted, refetched per session.
    var collections: [UCollection] = []
    var collectionsPage: UInt32 = 0
    var collectionsHasNext = false
    var isLoadingCollections = false
    var collectionsError: String?
    /// Collections list: title/slug filter (session-scoped, like fandoms).
    var collectionsListFilter = ""
    private(set) var collectionsTask = NetworkTask()
    /// Collection drill-in: URL slug + display title of the open collection,
    /// whose works show in the reading pane via the search-results flow.
    var collectionWorksName: String?
    var collectionWorksTitle: String?

    var filteredCollections: [UCollection] {
        let needle = collectionsListFilter.trimmingCharacters(in: .whitespaces).lowercased()
        guard !needle.isEmpty else { return collections }
        return collections.filter {
            $0.title.lowercased().contains(needle) || $0.name.lowercased().contains(needle)
        }
    }

    /// Fetch the next /collections index page (page 1 when nothing is loaded).
    func loadMoreCollections() {
        guard !isLoadingCollections else { return }
        isLoadingCollections = true
        collectionsError = nil
        let page = collectionsPage + 1
        let task = NetworkTask()
        collectionsTask = task
        Task { @MainActor in
            do {
                let result = try await appState.retryOnTimeout(task: task, using: appState.bridge) {
                    try await self.appState.bridge.browseCollections(page: page)
                }
                let existing = Set(collections.map(\.name))
                collections.append(contentsOf: result.collections.filter { !existing.contains($0.name) })
                collectionsPage = page
                collectionsHasNext = result.hasNextPage
            } catch {
                if !task.isCancelled && !error.isCancellation {
                    collectionsError = error.localizedDescription
                }
            }
            isLoadingCollections = false
        }
    }

    func cancelCollectionsLoad() {
        collectionsTask.cancel()
    }

    /// Collection drill-in: the collection's paged works in the reading pane
    /// without leaving the Collections section — the search-results flow
    /// (pager and all) driven by a collection query. The counts steer that
    /// query's shape (works pane, bookmarks pane, or both, side by side).
    func openCollectionWorks(slug: String, title: String,
                             workCount: UInt32 = 0, bookmarkedCount: UInt32 = 0) {
        collectionWorksName = slug
        collectionWorksTitle = title
        selectedWorkID = nil
        readerOpen = false
        immersive = false
        // startCollectionQuery also caches the collection's profile
        // metadata + tags — one shared entry point for every path here.
        Task { @MainActor in
            search.startCollectionQuery(slug, title: title,
                                        workCount: workCount,
                                        bookmarkedCount: bookmarkedCount,
                                        appState: appState)
        }
    }

    func closeCollectionWorks() {
        collectionWorksName = nil
        collectionWorksTitle = nil
        selectedWorkID = nil
        readerOpen = false
        Task { @MainActor in
            search.closeSplitCollection()
        }
    }

    func followAuthor(_ name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, !followedAuthorNames.contains(trimmed) else { return }
        followedAuthorNames.append(trimmed)
        appState.bridge.addFollowed(kind: "author", name: trimmed)
    }

    func unfollowAuthor(_ name: String) {
        followedAuthorNames.removeAll { $0 == name }
        appState.bridge.removeFollowed(kind: "author", name: name)
    }

    // MARK: - Sample data (testing/demo)

    /// Sample works use slug IDs ("baker") while real AO3 works use numeric
    /// IDs — and every bridge persistence call guards on UInt64(id), so
    /// samples exist in memory only and never touch the encrypted library.
    var sampleDataLoaded: Bool {
        appState.fetchedWorks.keys.contains { UInt64($0) == nil }
    }

    func loadSampleData() {
        for work in MockData.works {
            appState.fetchedWorks[work.id] = work
        }
        // Seed library state so every section has examples.
        appState.progressMap["baker"] = ReadingProgress(chapter: 4, pos: 1180, chapterLen: 3100)
        appState.progressMap["olive"] = ReadingProgress(chapter: 17, pos: 4930, chapterLen: 6950)
        for id in ["lamplight", "baker"] where !appState.history.contains(id) {
            appState.history.append(id)
        }
        appState.bookmarkedWorkIDs.formUnion(["lamplight", "olive", "garden"])
        appState.downloadedWorkIDs.formUnion(MockData.works.filter(\.downloaded).map(\.id))
    }

    func clearSampleData() {
        let isSample: (String) -> Bool = { UInt64($0) == nil }
        appState.fetchedWorks = appState.fetchedWorks.filter { !isSample($0.key) }
        appState.fetchedChapters = appState.fetchedChapters.filter { !isSample($0.key) }
        appState.progressMap = appState.progressMap.filter { !isSample($0.key) }
        appState.history.removeAll(where: isSample)
        appState.lastReadID = appState.history.first
        appState.bookmarkedWorkIDs = appState.bookmarkedWorkIDs.filter { !isSample($0) }
        appState.downloadedWorkIDs = appState.downloadedWorkIDs.filter { !isSample($0) }
        appState.kudosGivenWorkIDs = appState.kudosGivenWorkIDs.filter { !isSample($0) }
        if let selected = selectedWorkID, isSample(selected) {
            selectedWorkID = nil
            readerOpen = false
            immersive = false
        }
    }

    // MARK: - Subscription drill-in (stays inside Subscriptions)

    /// When set, the reading pane shows this subscription's associated works.
    var subscriptionWorksTitle: String?
    var subscriptionWorksList: [Work] = []
    var isLoadingSubscriptionWorks = false
    var subscriptionWorksError: String?
    /// Drives the inline spinner on the tapped subscription row.
    var loadingSubscriptionID: String?
    /// Subscription identity for cache persistence.
    var subscriptionWorksSubType: String = ""
    var subscriptionWorksSubId: String?
    /// Progress line while a full works crawl is running ("Page 3 of 12 · 47 works…").
    var subscriptionWorksFetchStatus: String?
    /// When this drill-in's works were last fully crawled (epoch-seconds
    /// string from the DB) — drives the "refreshed 3d ago" staleness line.
    var subscriptionWorksCrawledAt: String?

    var filteredSubscriptionWorks: [Work] {
        works(for: .subscriptions)
    }

    /// Show a subscription's locally stored works (author or series). Never
    /// fetches — a complete, current list comes from Refresh Works.
    /// `subscriptionID` is the parsed AO3 username (author) or series ID;
    /// `author` is only the display name and may differ from it.
    /// Whether the reading pane shows the drilled-in author's profile
    /// instead of their works list. Toggled by the header's person button.
    var showingAuthorProfile = false

    func openSubscriptionAuthorWorks(subscriptionID: String, author: String, subType: String = "author") {
        authorTask.cancel()
        if subscriptionWorksSubId != subscriptionID { listEmptied(.subscriptions) }
        showingAuthorProfile = false
        subscriptionWorksTitle = author
        subscriptionWorksError = nil
        subscriptionWorksFetchStatus = nil
        isLoadingSubscriptionWorks = false
        loadingSubscriptionID = nil
        selectedWorkID = nil
        readerOpen = false
        subscriptionWorksSubType = subType
        subscriptionWorksSubId = subscriptionID
        subscriptionWorksCrawledAt = appState.bridge.getWorksCrawledAt(subType: subType, subId: subscriptionID)

        let cached = appState.bridge.getSubscriptionWorks(subType: subType, subId: subscriptionID)
        let works = cached.map(AppState.workFromSummary)
        for work in works { appState.fetchedWorks[work.id] = work }
        subscriptionWorksList = works
    }

    /// Fetch the subscription's complete works list — every page on AO3.
    /// Author subscriptions crawl /users/{name}/works; series crawl /series/{id}.
    func refreshSubscriptionWorks() {
        guard let subId = subscriptionWorksSubId, !isLoadingSubscriptionWorks else { return }
        let subType = subscriptionWorksSubType
        subscriptionWorksError = nil
        isLoadingSubscriptionWorks = true
        loadingSubscriptionID = subId
        let task = NetworkTask()
        authorTask = task
        let fetchPage: (UInt32) async throws -> UPagedWorks
        if subType.lowercased().contains("series"), let seriesId = UInt64(subId) {
            fetchPage = { [appState] in
                try await appState.bridge.fetchSeriesWorksPaged(seriesId: seriesId, page: $0)
            }
        } else {
            fetchPage = { [appState] in
                try await appState.bridge.fetchAuthorWorks(username: subId, page: $0)
            }
        }
        Task { @MainActor in
            do {
                let all = try await crawlAllWorks(
                    fetchPage: fetchPage, task: task,
                    status: { [weak self] in self?.subscriptionWorksFetchStatus = $0 },
                    partial: { [weak self] works in
                        guard let self, subscriptionWorksSubId == subId else { return }
                        subscriptionWorksList = works
                    })
                if subscriptionWorksSubId == subId && !task.isCancelled {
                    subscriptionWorksList = all
                    let ids = all.map { UInt64($0.id) ?? 0 }.filter { $0 > 0 }
                    appState.bridge.saveSubscriptionWorks(subType: subType, subId: subId, workIds: ids)
                    appState.bridge.setWorksCrawledNow(subType: subType, subId: subId)
                    subscriptionWorksCrawledAt = appState.bridge.getWorksCrawledAt(subType: subType, subId: subId)
                    // The crawl rewrote works in the DB (author renames,
                    // updated stats) — refresh the launch-time snapshot too.
                    appState.reloadCachedWorks()
                }
            } catch {
                if !task.isCancelled && !error.isCancellation,
                   subscriptionWorksSubId == subId {
                    subscriptionWorksError = error.localizedDescription
                }
            }
            if subscriptionWorksSubId == subId {
                isLoadingSubscriptionWorks = false
                subscriptionWorksFetchStatus = nil
                loadingSubscriptionID = nil
            }
        }
    }

    func cancelSubscriptionWorksRefresh() {
        authorTask.cancel()
    }

    func closeSubscriptionWorks() {
        authorTask.cancel()
        listEmptied(.subscriptions)
        showingAuthorProfile = false
        subscriptionWorksTitle = nil
        subscriptionWorksList = []
        subscriptionWorksError = nil
        subscriptionWorksFetchStatus = nil
        subscriptionWorksSubId = nil
        selectedWorkID = nil
    }

    // MARK: - Author works browsing

    var authorUsername: String?
    var authorWorksList: [Work] = []
    /// Last completed full crawl for this author (epoch-seconds string).
    var authorWorksCrawledAt: String?

    var filteredAuthorWorks: [Work] {
        works(for: .authors)
    }
    var isLoadingAuthor = false
    var authorError: String?
    /// Progress line while a full works crawl is running.
    var authorFetchStatus: String?
    /// The in-flight crawl's task. Each crawl gets its own instance so that
    /// cancelling one can never be undone by a later crawl's retry reset.
    private(set) var authorTask = NetworkTask()

    /// Show an author's locally stored works. Never fetches — a complete,
    /// current list comes from the user pressing Refresh Works.
    func openAuthor(_ username: String) {
        authorTask.cancel()
        if authorUsername != username { listEmptied(.authors, .authorWorks) }
        showingAuthorProfile = false
        authorUsername = username
        authorError = nil
        authorFetchStatus = nil
        isLoadingAuthor = false
        selectedWorkID = nil
        readerOpen = false

        authorWorksCrawledAt = appState.bridge.getWorksCrawledAt(subType: "author", subId: username)
        let cached = appState.bridge.getWorksByAuthor(username: username)
        let works = cached.map(AppState.workFromSummary)
        for work in works { appState.fetchedWorks[work.id] = work }
        authorWorksList = works
    }

    /// Fetch the author's complete works list — every page on AO3.
    func refreshAuthorWorks() {
        guard let username = authorUsername, !isLoadingAuthor else { return }
        authorError = nil
        isLoadingAuthor = true
        let task = NetworkTask()
        authorTask = task
        Task { @MainActor in
            do {
                let all = try await crawlAllWorks(
                    fetchPage: { [appState] in
                        try await appState.bridge.fetchAuthorWorks(username: username, page: $0)
                    },
                    task: task,
                    status: { [weak self] in self?.authorFetchStatus = $0 },
                    partial: { [weak self] works in
                        guard let self, authorUsername == username else { return }
                        authorWorksList = works
                    })
                if authorUsername == username && !task.isCancelled {
                    appState.bridge.setWorksCrawledNow(subType: "author", subId: username)
                    authorWorksCrawledAt = appState.bridge.getWorksCrawledAt(subType: "author", subId: username)
                    appState.reloadCachedWorks()
                    // Show the cache union, not just the crawl result: works
                    // that disappeared from AO3 stay on the author's list.
                    let cached = appState.bridge.getWorksByAuthor(username: username)
                    let works = cached.map(AppState.workFromSummary)
                    for work in works { appState.fetchedWorks[work.id] = work }
                    authorWorksList = works.isEmpty ? all : works
                }
            } catch {
                if !task.isCancelled && !error.isCancellation,
                   authorUsername == username {
                    authorError = error.localizedDescription
                }
            }
            if authorUsername == username {
                isLoadingAuthor = false
                authorFetchStatus = nil
            }
        }
    }

    func cancelAuthorWorksRefresh() {
        authorTask.cancel()
    }

    func closeAuthorWorks() {
        authorTask.cancel()
        listEmptied(.authors, .authorWorks)
        showingAuthorProfile = false
        authorUsername = nil
        authorWorksList = []
        authorError = nil
        authorFetchStatus = nil
        selectedWorkID = nil
    }

    /// Walk every page of a works listing on AO3 (author or series),
    /// delivering the accumulated list after each page and a human-readable
    /// progress line before each request. Works are persisted to the library
    /// by the Rust layer as they arrive. Stops early (returning what it has)
    /// if `task` is cancelled.
    @MainActor
    private func crawlAllWorks(fetchPage: @escaping (UInt32) async throws -> UPagedWorks,
                               task: NetworkTask,
                               status: (String) -> Void,
                               partial: ([Work]) -> Void) async throws -> [Work] {
        var all: [Work] = []
        var seen = Set<String>()
        var page: UInt32 = 1
        var totalPages: UInt32 = 1
        while true {
            if page == 1 {
                status("Fetching works from AO3…")
            } else {
                status("Fetching page \(page) of \(totalPages) · \(all.count) works so far…")
            }
            let result = try await appState.retryOnTimeout(task: task, using: appState.bridge) {
                try await fetchPage(page)
            }
            totalPages = max(result.totalPages, page)
            let works = result.works.map(AppState.workFromSummary)
            for work in works where seen.insert(work.id).inserted {
                appState.fetchedWorks[work.id] = work
                all.append(work)
            }
            partial(all)
            if !result.hasNextPage || task.isCancelled { break }
            page += 1
        }
        return all
    }

    // MARK: - Lists

    /// Book-level completion fraction for list progress bars.
    func progress(for work: Work) -> Double {
        guard let p = appState.progressMap[work.id] else { return 0 }
        let chapters = max(1, work.totalChapters)
        return min(1, (Double(p.chapter - 1) + p.pct) / Double(chapters))
    }

    var currentlyReading: [Work] {
        appState.progressMap.keys
            .compactMap { appState.work(byID: $0) }
            .sorted {
                // Most recently read first; works never stamped (read
                // before last_read_dt existed) sink to the bottom.
                let a = appState.lastReadMap[$0.id] ?? ""
                let b = appState.lastReadMap[$1.id] ?? ""
                if a.isEmpty != b.isEmpty { return b.isEmpty }
                if a != b { return a > b }
                return $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending
            }
    }

    func works(for section: Section) -> [Work] {
        filterAndSort(rawWorks(for: section),
                      query: query(for: section, sectionFilters: true, listFilter: true,
                                   sort: workSort(for: section)))
    }

    private func rawWorks(for section: Section) -> [Work] {
        switch section {
        case .browse:
            appState.browseResults
        case .search:
            appState.searchResults
        case .reading:
            currentlyReading
        case .history:
            appState.history.compactMap { appState.work(byID: $0) }
        case .bookmarks:
            appState.bookmarkedWorkIDs.compactMap { appState.work(byID: $0) }
                .sorted { $0.title < $1.title }
        case .readingLists:
            selectedReadingListID.map { appState.worksInReadingList($0) } ?? []
        case .downloads:
            appState.downloadedWorkIDs.compactMap { appState.work(byID: $0) }
                .sorted { $0.title < $1.title }
        case .authorWorks:
            authorWorksList
        case .whatsNew:
            appState.newWorkIDs.compactMap { appState.work(byID: $0) }
        // Reading-pane drill-ins: the works lists shown while these
        // sections are active (feeds availableTags + the shared filter).
        case .subscriptions:
            subscriptionWorksList
        case .authors:
            authorWorksList
        case .fandoms:
            fandomLibraryWorksRaw
        default:
            []
        }
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
            hideExplicit: sectionFilters && hideExplicit,
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
    private func filterAndSort(_ works: [Work], query: UWorkListQuery) -> [Work] {
        let ids = works.compactMap { UInt64($0.id) }
        guard ids.count == works.count else { return works }
        let ordered = appState.bridge.filterAndSortWorks(ids: ids, query: query)
        let byID = Dictionary(works.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        return ordered.compactMap { byID[String($0)] }
    }

    // MARK: - 2nd-pane list filters (session-scoped, tailored per content type)

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
    func availableTags(for s: Section) -> [String] {
        filterOptions(for: s).tags
    }

    /// Distinct fandoms across a section's (pre-list-filter) work list — the
    /// suggestion pool for the filter dialog's fandom field.
    func availableFandoms(for s: Section) -> [String] {
        filterOptions(for: s).fandoms
    }

    private func filterOptions(for s: Section) -> UWorkFilterOptions {
        let raw = rawWorks(for: s)
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

    // MARK: - Derived library views

    struct FandomEntry: Identifiable {
        let name: String, count: Int
        var id: String { name }
    }

    /// Fandoms represented in the local library (cached works). Each work
    /// counts under every fandom it's tagged with, so crossovers appear in
    /// both lists.
    var libraryFandoms: [FandomEntry] {
        var counts: [String: Int] = [:]
        for work in appState.cachedWorks {
            let fandoms = work.fandoms.isEmpty ? [work.fandom] : work.fandoms
            for fandom in fandoms {
                counts[fandom, default: 0] += 1
            }
        }
        return counts.sorted { $0.value > $1.value }.map { FandomEntry(name: $0.key, count: $0.value) }
    }

    /// Authors the user follows (from AO3 subscriptions).
    var followedAuthors: [USubscription] {
        appState.subscriptions.filter {
            let t = $0.subType.lowercased()
            return t.contains("user") || t.contains("author")
        }
    }

    struct LocalStats {
        let wordsRead: Int, worksFinished: Int, inLibrary: Int, downloaded: Int
    }

    /// Stats computed on device from progress + cached works.
    var localStats: LocalStats {
        var wordsRead = 0
        var finished = 0
        for (id, progress) in appState.progressMap {
            guard let work = appState.work(byID: id) else { continue }
            let chapters = max(1, work.totalChapters)
            let fraction = min(1, (Double(progress.chapter - 1) + progress.pct) / Double(chapters))
            wordsRead += Int(Double(work.words) * fraction)
            if fraction >= 0.99 { finished += 1 }
        }
        return LocalStats(wordsRead: wordsRead, worksFinished: finished,
                          inLibrary: appState.cachedWorks.count,
                          downloaded: appState.downloadedWorkIDs.count)
    }
}
