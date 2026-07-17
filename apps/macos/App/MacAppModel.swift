import Foundation
import Observation

/// Navigation + selection state for the three-pane reader. Pure UI state —
/// all library data, network fetching, and persistence live in the shared
/// AppState/RustBridge, exactly as on iOS.
@Observable
final class MacAppModel {
    enum Section: String, CaseIterable {
        case browse, reading, history, subscriptions, inbox, fandoms, authors,
             bookmarks, downloads, stats, search, authorWorks
    }

    let appState: AppState
    let search: MacSearchModel

    /// The app opens on Currently Reading — the primary use case.
    var section: Section = .reading
    var subscriptionSubTab: String = "new"
    var selectedWorkID: String?
    var readerOpen = false
    var readerChapter = 0
    var immersive = false
    var query = ""
    var activeTags: Set<String> = []
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

    // MARK: - Intents

    func goSection(_ s: Section) {
        if section == .inbox && s != .inbox {
            appState.clearInboxSelection()
        }
        if section == .authors && s != .authors {
            closeAuthorWorks()
        }
        section = s
        selectedReadingListID = nil
        subscriptionWorksTitle = nil
        readerOpen = false
        switch s {
        case .browse:
            if appState.browseResults.isEmpty {
                Task { await appState.browseLatestWorks() }
            }
        case .search:
            Task { await search.loadFormIfNeeded(appState) }
        case .subscriptions:
            Task { await appState.loadSubscriptions() }
            appState.loadNotifications()
        case .inbox:
            appState.loadCachedInbox()
            Task { await appState.checkInbox() }
        default:
            break
        }
    }

    func goReadingList(_ listID: Int64) {
        section = .bookmarks
        selectedReadingListID = listID
        readerOpen = false
    }

    func selectWork(_ id: String) {
        if selectedWorkID != id { selectedWorkID = id }
        if readerOpen { readerOpen = false }
        // Fill in full metadata (tags, summary, chapter titles) if the row
        // came from a listing with partial data.
        Task { await appState.fetchWorkMetadata(id) }
    }

    func openReader(_ id: String, chapter: Int) {
        selectedWorkID = id
        readerChapter = chapter
        readerOpen = true
        appState.pushHistory(id)
        // Opening a chapter enrolls the work in Currently Reading immediately —
        // scrolling only refines the position. Progress is monotonic, so
        // revisiting an earlier chapter never regresses anything.
        appState.setProgress(id, chapter: chapter + 1, pct: 0)
    }

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
        section = .search
        readerOpen = false
        selectedWorkID = nil
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
        section = .search
        readerOpen = false
        selectedWorkID = nil
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
        filtered(subscriptionWorksList)
    }

    /// Show a subscription's locally stored works. Never fetches — a complete,
    /// current list comes from the user pressing Refresh Works.
    /// `subscriptionID` is the parsed AO3 username for author subscriptions;
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

    /// Fetch the author's complete works list — every page on AO3.
    func refreshSubscriptionWorks() {
        guard let subId = subscriptionWorksSubId, !isLoadingSubscriptionWorks else { return }
        let subType = subscriptionWorksSubType
        subscriptionWorksError = nil
        isLoadingSubscriptionWorks = true
        loadingSubscriptionID = subId
        let task = NetworkTask()
        authorTask = task
        Task { @MainActor in
            do {
                let all = try await crawlAllAuthorWorks(
                    username: subId, task: task,
                    status: { [weak self] in self?.subscriptionWorksFetchStatus = $0 },
                    partial: { [weak self] works in
                        guard let self, subscriptionWorksSubId == subId else { return }
                        subscriptionWorksList = works
                    })
                if subscriptionWorksSubId == subId && !task.isCancelled {
                    subscriptionWorksList = all
                    let ids = all.map { UInt64($0.id) ?? 0 }.filter { $0 > 0 }
                    appState.bridge.saveSubscriptionWorks(subType: subType, subId: subId, workIds: ids)
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
                let all = try await crawlAllAuthorWorks(
                    username: username, task: task,
                    status: { [weak self] in self?.authorFetchStatus = $0 },
                    partial: { [weak self] works in
                        guard let self, authorUsername == username else { return }
                        authorWorksList = works
                    })
                if authorUsername == username && !task.isCancelled {
                    authorWorksList = all
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

    /// Walk every page of an author's works on AO3, delivering the accumulated
    /// list after each page and a human-readable progress line before each
    /// request. Works are persisted to the library by the Rust layer as they
    /// arrive. Stops early (returning what it has) if `task` is cancelled.
    @MainActor
    private func crawlAllAuthorWorks(username: String,
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
                try await self.appState.bridge.fetchAuthorWorks(username: username, page: page)
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
        let works: [Work]
        switch section {
        case .browse:
            works = appState.browseResults
        case .search:
            works = appState.searchResults
        case .reading:
            works = currentlyReading
        case .history:
            works = appState.history.compactMap { appState.work(byID: $0) }
        case .bookmarks:
            if let listID = selectedReadingListID {
                works = appState.worksInReadingList(listID)
            } else {
                works = appState.bookmarkedWorkIDs.compactMap { appState.work(byID: $0) }
                    .sorted { $0.title < $1.title }
            }
        case .downloads:
            works = appState.downloadedWorkIDs.compactMap { appState.work(byID: $0) }
                .sorted { $0.title < $1.title }
        case .authorWorks:
            works = authorWorksList
        case .subscriptions:
            works = appState.newWorkIDs.compactMap { appState.work(byID: $0) }
        default:
            works = []
        }
        return filtered(works)
    }

    private func filtered(_ works: [Work]) -> [Work] {
        works.filter { w in
            let passesRating = !hideExplicit || w.rating != .explicit
            let matchesTags = activeTags.allSatisfy { w.tags.contains($0) }
            return passesRating && matchesTags
        }
    }

    /// Tag chips for browse: most common tags among current results.
    var availableTags: [String] {
        var counts: [String: Int] = [:]
        for work in appState.browseResults {
            for tag in work.tags { counts[tag, default: 0] += 1 }
        }
        return counts.sorted { $0.value > $1.value }.prefix(10).map(\.key)
    }

    // MARK: - Derived library views

    struct FandomEntry: Identifiable {
        let name: String, count: Int
        var id: String { name }
    }

    /// Fandoms represented in the local library (cached works).
    var libraryFandoms: [FandomEntry] {
        var counts: [String: Int] = [:]
        for work in appState.cachedWorks {
            counts[work.fandom, default: 0] += 1
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
