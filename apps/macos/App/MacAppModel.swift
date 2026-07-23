import Foundation
import Observation

/// Navigation + selection state for the three-pane reader. Pure UI state —
/// all library data, network fetching, and persistence live in the shared
/// AppState/RustBridge, exactly as on iOS.
@Observable
final class MacAppModel {
    enum Section: String, CaseIterable {
        case browse, reading, history, subscriptions, whatsNew, inbox, fandoms, authors,
             bookmarks, downloads, stats, search, authorWorks
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
    }

    var selectedWork: Work? {
        selectedWorkID.flatMap { appState.work(byID: $0) }
    }

    /// Everything the app is fetching right now, for summarized loading
    /// feedback. Combines shared AppState flags with Mac-local operations.
    var inFlightOperations: [String] {
        var ops: [String] = []
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
        if search.isLoadingForm { ops.append("Loading search criteria") }
        if let sync = appState.bookmarkSyncTask.statusMessage { ops.append(sync) }
        return ops
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

    /// Per-section sort choice (persisted; sections not present sort naturally).
    private var workSorts: [String: String] =
        UserDefaults.standard.dictionary(forKey: "workSorts") as? [String: String] ?? [:] {
        didSet { UserDefaults.standard.set(workSorts, forKey: "workSorts") }
    }

    func workSort(for section: Section) -> WorkSort {
        WorkSort(rawValue: workSorts[String(describing: section)] ?? "") ?? .natural
    }

    func setWorkSort(_ sort: WorkSort, for section: Section) {
        workSorts[String(describing: section)] = sort.rawValue
    }

    var completionFilter: CompletionFilter =
        CompletionFilter(rawValue: UserDefaults.standard.string(forKey: "completionFilter") ?? "") ?? .all {
        didSet { UserDefaults.standard.set(completionFilter.rawValue, forKey: "completionFilter") }
    }

    var ratingFilter: Rating? =
        UserDefaults.standard.string(forKey: "ratingFilter").flatMap(Rating.init(rawValue:)) {
        didSet { UserDefaults.standard.set(ratingFilter?.rawValue, forKey: "ratingFilter") }
    }

    /// Sort a filtered list by the section's persisted choice. Dates are
    /// ISO-normalized (yyyy-mm-dd) so string comparison orders correctly.
    func sorted(_ works: [Work], for section: Section) -> [Work] {
        switch workSort(for: section) {
        case .natural: works
        case .updated: works.sorted { $0.updated > $1.updated }
        case .kudos: works.sorted { $0.kudos > $1.kudos }
        case .words: works.sorted { $0.words > $1.words }
        case .title: works.sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
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
                readerResumePct = progress.pct
            } else {
                readerResumePct = 0
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
        default:
            break
        }
    }

    func goReadingList(_ listID: Int64) {
        if section != .bookmarks {
            snapshotPane(for: section)
            section = .bookmarks
            restorePane(for: .bookmarks)
        }
        selectedReadingListID = listID
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
        return false
    }

    func selectWork(_ id: String) {
        if selectedWorkID != id { selectedWorkID = id }
        if readerOpen { readerOpen = false }
        // Fill in full metadata (tags, summary, chapter titles) if the row
        // came from a listing with partial data.
        Task { await appState.fetchWorkMetadata(id) }
    }

    func openReader(_ id: String, chapter: Int) {
        // Stash the saved in-chapter position before setProgress(pct: 0)
        // overwrites it — the reader consumes this to restore the scroll.
        if let existing = appState.progressMap[id], existing.chapter == chapter + 1 {
            readerResumePct = existing.pct
        } else {
            readerResumePct = 0
        }
        selectedWorkID = id
        readerChapter = chapter
        readerOpen = true
        appState.pushHistory(id)
        // Opening a chapter enrolls the work in Currently Reading immediately —
        // scrolling only refines the position. Progress is monotonic, so
        // revisiting an earlier chapter never regresses anything.
        appState.setProgress(id, chapter: chapter + 1, pct: 0)
    }

    /// Saved scroll position (0–1) for the chapter being opened; consumed by
    /// the reader on its first successful render.
    var readerResumePct: Double = 0

    func closeReader() {
        readerOpen = false
        immersive = false
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

    var followedFandoms: [String] = UserDefaults.standard.stringArray(forKey: "followedFandoms") ?? [] {
        didSet { UserDefaults.standard.set(followedFandoms, forKey: "followedFandoms") }
    }
    var followedAuthorNames: [String] = UserDefaults.standard.stringArray(forKey: "followedAuthors") ?? [] {
        didSet { UserDefaults.standard.set(followedAuthorNames, forKey: "followedAuthors") }
    }

    /// Fandom drill-in: a followed fandom's works shown in the reading pane
    /// without ever leaving the Fandoms section. Local-first — opening shows
    /// the library's works for that fandom; AO3 is only searched on the
    /// explicit toolbar action.
    var fandomWorksTag: String?
    var fandomSearchActive = false

    func openFandomWorks(_ tag: String) {
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
        fandomWorksTag = nil
        fandomSearchActive = false
        selectedWorkID = nil
    }

    /// Library works for the open fandom — matched against every fandom tag
    /// on the work (crossovers count), the same tally the Fandoms list rows
    /// show.
    var fandomLibraryWorks: [Work] {
        applyListFilter(fandomLibraryWorksRaw, for: .fandoms)
    }

    private var fandomLibraryWorksRaw: [Work] {
        guard let tag = fandomWorksTag else { return [] }
        return appState.cachedWorks.filter { $0.fandoms.contains(tag) || $0.fandom == tag }
    }

    func followFandom(_ name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, !followedFandoms.contains(trimmed) else { return }
        followedFandoms.append(trimmed)
    }

    func unfollowFandom(_ name: String) {
        followedFandoms.removeAll { $0 == name }
    }

    func followAuthor(_ name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, !followedAuthorNames.contains(trimmed) else { return }
        followedAuthorNames.append(trimmed)
    }

    func unfollowAuthor(_ name: String) {
        followedAuthorNames.removeAll { $0 == name }
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
        appState.progressMap["baker"] = ReadingProgress(chapter: 4, pct: 0.38)
        appState.progressMap["olive"] = ReadingProgress(chapter: 17, pct: 0.71)
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

    var filteredSubscriptionWorks: [Work] {
        sorted(applyListFilter(filtered(subscriptionWorksList), for: .subscriptions), for: .subscriptions)
    }

    /// Show a subscription's locally stored works (author or series). Never
    /// fetches — a complete, current list comes from Refresh Works.
    /// `subscriptionID` is the parsed AO3 username (author) or series ID;
    /// `author` is only the display name and may differ from it.
    func openSubscriptionAuthorWorks(subscriptionID: String, author: String, subType: String = "author") {
        authorTask.cancel()
        subscriptionWorksTitle = author
        subscriptionWorksError = nil
        subscriptionWorksFetchStatus = nil
        isLoadingSubscriptionWorks = false
        loadingSubscriptionID = nil
        selectedWorkID = nil
        readerOpen = false
        subscriptionWorksSubType = subType
        subscriptionWorksSubId = subscriptionID

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
                    // The crawl rewrote works in the DB (author renames,
                    // updated stats) — refresh the launch-time snapshot too.
                    appState.reloadCachedWorks()
                }
            } catch {
                if !task.isCancelled && !"\(error)".contains("cancelled"),
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

    var filteredAuthorWorks: [Work] {
        sorted(applyListFilter(filtered(authorWorksList), for: .authors), for: .authors)
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
        authorUsername = username
        authorError = nil
        authorFetchStatus = nil
        isLoadingAuthor = false
        selectedWorkID = nil
        readerOpen = false

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
                    authorWorksList = all
                    appState.reloadCachedWorks()
                }
            } catch {
                if !task.isCancelled && !"\(error)".contains("cancelled"),
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
            .sorted { appState.history.firstIndex(of: $0.id) ?? .max < appState.history.firstIndex(of: $1.id) ?? .max }
    }

    func works(for section: Section) -> [Work] {
        sorted(applyListFilter(filtered(rawWorks(for: section)), for: section), for: section)
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
            if let listID = selectedReadingListID {
                appState.worksInReadingList(listID)
            } else {
                appState.bookmarkedWorkIDs.compactMap { appState.work(byID: $0) }
                    .sorted { $0.title < $1.title }
            }
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

    private func filtered(_ works: [Work]) -> [Work] {
        works.filter { w in
            let passesExplicit = !hideExplicit || w.rating != .explicit
            let passesCompletion = switch completionFilter {
            case .all: true
            case .complete: w.complete
            case .inProgress: !w.complete
            }
            let passesRating = ratingFilter == nil || w.rating == ratingFilter
            return passesExplicit && passesCompletion && passesRating
        }
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
    /// Fandoms list: fandom name.
    var fandomsListFilter = ""
    /// Inbox: three targeted fields.
    var inboxFilterAuthor = ""
    var inboxFilterWork = ""
    var inboxFilterText = ""

    func workListFilter(for s: Section) -> WorkListFilter {
        workListFilters[s] ?? WorkListFilter()
    }

    private func applyListFilter(_ works: [Work], for s: Section) -> [Work] {
        guard let filter = workListFilters[s], filter.isActive else { return works }
        let needle = filter.text.trimmingCharacters(in: .whitespaces).lowercased()
        return works.filter { w in
            let textOK = needle.isEmpty
                || w.title.lowercased().contains(needle)
                || w.author.lowercased().contains(needle)
                || w.summary.lowercased().contains(needle)
            // Tag/fandom selections are OR within their group: a work matches
            // if it carries ANY selected tag / ANY selected fandom.
            let tagsOK = filter.tags.isEmpty || w.tags.contains { filter.tags.contains($0) }
            let workFandoms = w.fandoms.isEmpty ? [w.fandom] : w.fandoms
            let fandomsOK = filter.fandoms.isEmpty || workFandoms.contains { filter.fandoms.contains($0) }
            let kudosOK = Self.matchesCount(w.kudos, expression: filter.kudos)
            let wordsOK = Self.matchesCount(w.words, expression: filter.words)
            return textOK && tagsOK && fandomsOK && kudosOK && wordsOK
        }
    }

    /// ">" / "<" prefixed comparisons; a plain number means "at least".
    /// Unparseable input filters nothing.
    private static func matchesCount(_ value: Int, expression: String) -> Bool {
        let trimmed = expression.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return true }
        if trimmed.hasPrefix(">") {
            guard let n = Int(trimmed.dropFirst().trimmingCharacters(in: .whitespaces)) else { return true }
            return value > n
        }
        if trimmed.hasPrefix("<") {
            guard let n = Int(trimmed.dropFirst().trimmingCharacters(in: .whitespaces)) else { return true }
            return value < n
        }
        guard let n = Int(trimmed) else { return true }
        return value >= n
    }

    /// Distinct tags across a section's (pre-filter) work list,
    /// alphabetically — the suggestion pool for the filter dialog.
    func availableTags(for s: Section) -> [String] {
        var tags = Set<String>()
        for work in filtered(rawWorks(for: s)) {
            tags.formUnion(work.tags)
        }
        return tags.sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
    }

    /// Distinct fandoms across a section's (pre-filter) work list — the
    /// suggestion pool for the filter dialog's fandom field.
    func availableFandoms(for s: Section) -> [String] {
        var fandoms = Set<String>()
        for work in filtered(rawWorks(for: s)) {
            fandoms.formUnion(work.fandoms.isEmpty ? [work.fandom] : work.fandoms)
        }
        return fandoms.sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
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
