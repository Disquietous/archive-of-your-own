import SwiftUI

@Observable
final class AppState {
    let bridge = RustBridge()
    let sessionId = UUID().uuidString

    var bookmarkedWorkIDs: Set<String> = []
    var kudosGivenWorkIDs: Set<String> = []
    var downloadedWorkIDs: Set<String> = []
    var history: [String] = []
    var progressMap: [String: ReadingProgress] = [:]
    var lastReadID: String?
    var hideExplicit: Bool = UserDefaults.standard.bool(forKey: "hideExplicit") {
        didSet { UserDefaults.standard.set(hideExplicit, forKey: "hideExplicit") }
    }

    // Live search results from Rust backend
    var searchResults: [Work] = []
    var isSearching = false
    var searchError: String?

    // Cached works from SQLCipher (previously browsed/fetched)
    var cachedWorks: [Work] = []
    var readingLists: [UReadingList] = []

    // Account tracking for per-account data freshness
    var subscriptionsLoadedForAccount: String?
    var bookmarksLoadedForAccount: String?

    // Inbox
    var inboxUnreadCount: Int = 0

    // Subscriptions
    var subscriptions: [USubscription] = []
    var isLoadingSubscriptions = false
    var subscriptionError: String?
    let subscriptionLoadTask = NetworkTask()
    var unreadNotificationCount: Int = 0
    var notifications: [UNotification] = []
    var newWorkIDs: [String] = []
    var isCheckingSubscriptions = false
    let subscriptionCheckTask = NetworkTask()
    var subscriptionCheckTotal: Int = 0
    var subscriptionCheckRemaining: Int = 0

    init() {
        if bridge.launchState == .autoUnlock {
            _ = bridge.open()
        }
    }

    var torStatus: TorStatus { bridge.torStatus }

    // Connection state
    var isTestingCircuit = false
    var circuitAttempt = 0
    var isResolvingCloudflare = false
    var cloudflareResolved = false
    var cloudflareError: String?
    var torConnectCancelled = false
    var torConnectFailed = false
    var needsReauth = false

    func ensureAO3Login() async {
        guard !bridge.networkBlocked else { return }
        bridge.writeLog(level: "INFO", tag: "auth", message: "Ensuring AO3 login")
        let loggedIn = await bridge.ensureLoggedIn()
        bridge.writeLog(level: "INFO", tag: "auth", message: "Login result: \(loggedIn)")
        if loggedIn {
            bridge.saveSessionCookies()
            refreshAO3Username()
        }
    }

    func connectTor() async {
        let wasConnected = bridge.torStatus.isConnected
        // Always persist session cookies before the transport swap wipes the
        // jar — the Rust side refuses to overwrite authenticated cookies with
        // an anonymous jar, so this is safe even when logged out. (Previously
        // gated on wasConnected, which lost sessions established while
        // disconnected — surfacing as bogus "session expired" moments later.)
        bridge.saveSessionCookies()

        torConnectCancelled = false
        torConnectFailed = false
        var attempts = 0

        while !torConnectCancelled {
            await bridge.connectTor()
            guard bridge.torStatus.isConnected else {
                torConnectFailed = true
                return
            }

            attempts += 1
            isTestingCircuit = true
            circuitAttempt = attempts
            let healthy = await bridge.checkCircuitHealth()
            isTestingCircuit = false

            if torConnectCancelled { break }

            if healthy {
                bridge.writeLog(level: "INFO", tag: "health", message: "Circuit passed health check on attempt \(attempts)")
                await resolveCloudflare()
                // Always restore after the swap, not only on reconnects —
                // the new transport starts with an empty jar.
                bridge.restoreSessionCookies()
                torConnectFailed = false
                return
            }

            bridge.writeLog(level: "WARN", tag: "health", message: "Circuit failed health check (\(attempts)), trying another")
        }

        if torConnectCancelled {
            bridge.writeLog(level: "INFO", tag: "health", message: "Circuit search cancelled by user after \(attempts) attempts")
            torConnectFailed = true
        }
    }

    func cancelTorConnect() {
        torConnectCancelled = true
        isTestingCircuit = false
        isResolvingCloudflare = false
    }

    func proceedWithCurrentCircuit() async {
        cancelTorConnect()
        torConnectFailed = false
        bridge.writeLog(level: "WARN", tag: "health", message: "User chose to proceed with untested circuit")
        await resolveCloudflare()
    }

    /// Load AO3 in a hidden WKWebView routed through our Tor SOCKS proxy to
    /// pass Cloudflare's challenge and obtain the cf_clearance cookie.
    @MainActor
    func resolveCloudflare() async {
        let port = bridge.getSocksPort()
        guard port > 0 else {
            bridge.writeLog(level: "WARN", tag: "cloudflare", message: "Skipping: no SOCKS port")
            return
        }

        isResolvingCloudflare = true
        cloudflareError = nil
        bridge.writeLog(level: "INFO", tag: "cloudflare", message: "Starting challenge resolution via SOCKS port \(port)")

        do {
            let resolver = CloudflareResolver()
            let resolved = try await resolver.resolve(socksPort: port)

            // Restore auth cookies first (connectTor wiped them)
            bridge.restoreSessionCookies()

            // Then inject CF cookies on top
            if !resolved.cookies.isEmpty {
                bridge.injectCookies(resolved.cookies)
            }
            cloudflareResolved = true
            bridge.writeLog(level: "INFO", tag: "cloudflare",
                message: "Done: cf_clearance=\(resolved.hasCfClearance), \(resolved.cookies.count) CF cookies injected")
        } catch {
            cloudflareError = error.localizedDescription
            bridge.writeLog(level: "ERROR", tag: "cloudflare",
                message: "Resolution failed: \(error.localizedDescription)")
            // The transport swap emptied the jar before we got here; a failed
            // challenge must not also cost the login session.
            bridge.restoreSessionCookies()
        }

        isResolvingCloudflare = false
        bridge.cloudflareReady = true
    }

    func loadPersistedState() {
        guard bridge.isInitialized else { return }

        // Load cached works
        let works = bridge.getAllCachedWorks()
        cachedWorks = works.map(Self.workFromSummary)

        // Load bookmarks
        let bookmarkIDs = bridge.getBookmarkedWorkIds()
        bookmarkedWorkIDs = Set(bookmarkIDs.map { String($0) })

        // Load history (deduplicated, most recent first)
        let historyEntries = bridge.getHistory()
        var seen = Set<String>()
        history = historyEntries.compactMap { entry in
            let id = String(entry.workId)
            return seen.insert(id).inserted ? id : nil
        }
        lastReadID = history.first

        // Load progress
        let progressEntries = bridge.getAllProgress()
        progressMap = [:]
        for p in progressEntries {
            progressMap[String(p.workId)] = ReadingProgress(chapter: Int(p.chapter), pct: p.position)
        }

        // Intentionally downloaded works
        downloadedWorkIDs = Set(bridge.getDownloadedIds().map { String($0) })

        // Purge chapters for works that aren't downloaded or currently being read
        bridge.purgeStaleChapters()

        // Load reading lists
        readingLists = bridge.getReadingLists()

        // Restore AO3 session
        bridge.restoreSessionCookies()
        refreshAO3Username()

        // Verify session is still valid if we have an account
        if ao3Username != nil {
            Task { await ensureAO3Login() }
        }

        // Load notifications and What's New works
        loadNotifications()
        loadNewWorks()

        // Load persisted subscriptions (no network needed)
        if ao3Username != nil {
            let persisted = bridge.getPersistedSubscriptions()
            if !persisted.isEmpty {
                subscriptions = persisted
                subscriptionsLoadedForAccount = ao3Username
            }
        }

        // Auto-check subscriptions if stale (> 1 hour)
        if ao3Username != nil {
            let shouldCheck: Bool
            if let lastCheck = bridge.getLastSubscriptionCheck(),
               let epoch = TimeInterval(lastCheck) {
                shouldCheck = Date().timeIntervalSince1970 - epoch > 1 * 60 * 60
            } else {
                shouldCheck = true
            }
            if shouldCheck {
                Task { await checkSubscriptions() }
            }
        }
    }

    func refreshReadingLists() {
        readingLists = bridge.getReadingLists()
    }

    func createReadingList(_ name: String) {
        _ = bridge.createReadingList(name)
        refreshReadingLists()
    }

    func renameReadingList(_ listId: Int64, name: String) {
        bridge.renameReadingList(listId, name: name)
        refreshReadingLists()
    }

    func deleteReadingList(_ listId: Int64) {
        bridge.deleteReadingList(listId)
        refreshReadingLists()
    }

    func addToReadingList(_ listId: Int64, workId: String) {
        guard let id = UInt64(workId) else { return }
        bridge.addToReadingList(listId, workId: id)
        refreshReadingLists()
    }

    func removeFromReadingList(_ listId: Int64, workId: String) {
        guard let id = UInt64(workId) else { return }
        bridge.removeFromReadingList(listId, workId: id)
        refreshReadingLists()
    }

    func worksInReadingList(_ listId: Int64) -> [Work] {
        let ids = bridge.getReadingListItems(listId)
        return ids.compactMap { work(byID: String($0)) }
    }

    struct ReadingListSummary {
        let totalWords: Int
        let readCount: Int
        let totalCount: Int
        let topTags: [String]
    }

    func readingListSummary(_ listId: Int64) -> ReadingListSummary {
        let works = worksInReadingList(listId)
        let totalWords = works.reduce(0) { $0 + $1.words }
        let readCount = works.filter { w in
            guard let p = progressMap[w.id] else { return false }
            return p.pct >= 0.99
        }.count

        var tagCounts: [String: Int] = [:]
        for w in works {
            for tag in w.tags {
                tagCounts[tag, default: 0] += 1
            }
        }
        let topTags = tagCounts.sorted { $0.value > $1.value }.prefix(3).map(\.key)

        return ReadingListSummary(totalWords: totalWords, readCount: readCount, totalCount: works.count, topTags: topTags)
    }

    // All known works — cached from DB + fetched this session + from browse/search
    var allKnownWorks: [Work] {
        var seen = Set<String>()
        var result: [Work] = []
        for w in cachedWorks + fetchedWorks.values + browseResults + searchResults {
            if seen.insert(w.id).inserted { result.append(w) }
        }
        return result
    }

    var resumeWork: Work? {
        guard let id = lastReadID else { return nil }
        return work(byID: id)
    }

    var shelfWorks: [Work] {
        allKnownWorks.filter { w in
            downloadedWorkIDs.contains(w.id) || (progressMap[w.id]?.pct ?? 0) > 0
        }
    }

    var bookmarkedWorks: [Work] {
        allKnownWorks.filter { bookmarkedWorkIDs.contains($0.id) }
    }

    var historyWorks: [Work] {
        var seen = Set<String>()
        return history.compactMap { id -> Work? in
            guard seen.insert(id).inserted else { return nil }
            return work(byID: id)
        }
    }

    // Fetched work details from live data
    var fetchedWorks: [String: Work] = [:]
    var fetchedChapters: [String: [UChapter]] = [:]
    let browseTask = NetworkTask()
    let searchTask = NetworkTask()
    let metadataTask = NetworkTask()
    let downloadTask = NetworkTask()
    let bookmarkSyncTask = NetworkTask()

    func work(byID id: String) -> Work? {
        cachedWorks.first { $0.id == id }
        ?? browseResults.first { $0.id == id }
        ?? searchResults.first { $0.id == id }
        ?? fetchedWorks[id]
    }

    func fetchWorkMetadata(_ id: String) async {
        guard let workId = UInt64(id), fetchedWorks[id] == nil else { return }
        do {
            let summary = try await retryOnTimeout(task: metadataTask, using: bridge) {
                try await self.bridge.fetchWork(workId)
            }
            fetchedWorks[id] = Self.workFromSummary(summary)
        } catch {
            if !metadataTask.isCancelled && !"\(error)".contains("cancelled") {
                searchError = error.localizedDescription
            }
        }
    }

    func chaptersForWork(_ id: String) -> [UChapter]? {
        fetchedChapters[id]
    }

    func toggleBookmark(_ id: String) {
        if bookmarkedWorkIDs.contains(id) {
            if let workId = UInt64(id), bridge.isBookmarkSynced(workId) {
                pendingBookmarkRemoval = id
            } else {
                bookmarkedWorkIDs.remove(id)
                if let workId = UInt64(id) { bridge.removeBookmark(workId) }
            }
        } else {
            bookmarkedWorkIDs.insert(id)
            if let workId = UInt64(id) { bridge.addBookmark(workId, syncToAo3: false) }
        }
    }

    func confirmBookmarkRemoval() {
        guard let id = pendingBookmarkRemoval else { return }
        bookmarkedWorkIDs.remove(id)
        if let workId = UInt64(id) {
            Task {
                _ = try? await bridge.deleteAo3Bookmark(workId: workId)
                await MainActor.run {
                    self.bridge.removeBookmark(workId)
                }
            }
        }
        pendingBookmarkRemoval = nil
    }

    func cancelBookmarkRemoval() {
        pendingBookmarkRemoval = nil
    }

    func importAO3Bookmarks() async {
        guard let username = ao3Username else { return }
        bookmarkSyncTask.reset()
        bookmarkSyncTask.statusMessage = "Importing bookmarks..."
        do {
            let bookmarks = try await bridge.pullBookmarks(username: username)
            let ids = Set(bookmarks.map { String($0.workId) })
            bookmarkedWorkIDs.formUnion(ids)
            let works = bridge.getAllCachedWorks()
            cachedWorks = works.map(Self.workFromSummary)
            bookmarksLoadedForAccount = username
            bookmarkSyncTask.statusMessage = "Imported \(bookmarks.count) bookmarks"
        } catch let error as Ao3Error {
            if !bookmarkSyncTask.isCancelled {
                switch error {
                case .Network(let msg):
                    bookmarkSyncTask.statusMessage = "Import failed: \(msg)"
                default:
                    bookmarkSyncTask.statusMessage = "Import failed"
                }
            }
        } catch {
            if !bookmarkSyncTask.isCancelled {
                bookmarkSyncTask.statusMessage = "Import failed"
            }
        }
    }

    func pushBookmarkToAO3(_ id: String) async {
        guard let workId = UInt64(id) else { return }
        do {
            _ = try await bridge.pushBookmark(workId: workId)
        } catch {
            // Silently fail for individual pushes
        }
    }

    func pushAllSyncedBookmarks() async {
        bookmarkSyncTask.reset()
        bookmarkSyncTask.statusMessage = "Checking login..."

        bookmarkSyncTask.statusMessage = "Syncing bookmarks..."
        let syncedIds = bridge.getSyncedBookmarkIds()
        var pushed = 0
        for workId in syncedIds {
            if bookmarkSyncTask.isCancelled { break }
            do {
                _ = try await bridge.pushBookmark(workId: workId)
                pushed += 1
            } catch {
                continue
            }
        }
        if !bookmarkSyncTask.isCancelled {
            bookmarkSyncTask.statusMessage = "Synced \(pushed) bookmarks"
        }
    }

    func toggleKudos(_ id: String) {
        if kudosGivenWorkIDs.contains(id) {
            kudosGivenWorkIDs.remove(id)
        } else {
            kudosGivenWorkIDs.insert(id)
            if let workId = UInt64(id) {
                Task {
                    do {
                        let success = try await bridge.leaveKudos(workId: workId)
                        if !success {
                            _ = await MainActor.run { kudosGivenWorkIDs.remove(id) }
                        }
                    } catch {
                        _ = await MainActor.run { kudosGivenWorkIDs.remove(id) }
                    }
                }
            }
        }
    }

    var pendingBookmarkRemoval: String?

    var ao3Username: String?
    var ao3AccountCount = 0

    func refreshAO3Username() {
        let active = bridge.getActiveAccountUsername()
        ao3Username = active.isEmpty ? nil : active
        ao3AccountCount = bridge.getAccounts().count
    }

    func switchAccount(_ accountId: String) {
        let result = bridge.switchAccount(accountId: accountId)
        ao3Username = result.username.isEmpty ? nil : result.username

        if !result.hasSession && !result.username.isEmpty {
            needsReauth = true
        }

        // Invalidate per-account network data so views refetch
        subscriptionsLoadedForAccount = nil
        bookmarksLoadedForAccount = nil
        subscriptions = []

        // Reload per-account data from storage
        bookmarkedWorkIDs = Set(bridge.getBookmarkedWorkIds().map { String($0) })

        let progressEntries = bridge.getAllProgress()
        progressMap = [:]
        for p in progressEntries {
            progressMap[String(p.workId)] = ReadingProgress(chapter: Int(p.chapter), pct: p.position)
        }

        var seen = Set<String>()
        history = bridge.getHistory().compactMap { entry in
            let id = String(entry.workId)
            return seen.insert(id).inserted ? id : nil
        }
        lastReadID = history.first

        readingLists = bridge.getReadingLists()
        loadNotifications()
    }

    var downloadingWorkIDs: Set<String> = []

    func toggleDownload(_ id: String) {
        if downloadedWorkIDs.contains(id) {
            downloadedWorkIDs.remove(id)
            if let workId = UInt64(id) {
                bridge.unmarkDownloaded(workId)
            }
        } else {
            downloadedWorkIDs.insert(id)
            if let workId = UInt64(id) {
                bridge.markDownloaded(workId)
                Task { await downloadWork(id) }
            }
        }
    }

    func downloadWork(_ id: String) async {
        guard let workId = UInt64(id) else { return }
        downloadingWorkIDs.insert(id)
        do {
            let chapters = try await retryOnTimeout(task: downloadTask, using: bridge) {
                try await self.bridge.fetchChapters(workId)
            }
            fetchedChapters[id] = chapters
            if let cached = bridge.getCachedWork(workId) {
                fetchedWorks[id] = Self.workFromSummary(cached)
            }
        } catch {
            downloadedWorkIDs.remove(id)
        }
        downloadingWorkIDs.remove(id)
    }

    func isDownloading(_ id: String) -> Bool {
        downloadingWorkIDs.contains(id)
    }

    func pushHistory(_ id: String) {
        history.removeAll { $0 == id }
        history.insert(id, at: 0)
        lastReadID = id
        if let workId = UInt64(id) {
            bridge.addToHistory(workId)
            bridge.setCurrentWork(workId)
            bridge.purgeStaleChapters()
        }
    }

    func setProgress(_ id: String, chapter: Int, pct: Double) {
        let existing = progressMap[id]
        let highestChapter = max(chapter, existing?.chapter ?? 0)
        let storedPct = chapter == highestChapter ? pct : (existing?.pct ?? 0)
        progressMap[id] = ReadingProgress(chapter: highestChapter, pct: storedPct)
        if let workId = UInt64(id) {
            bridge.saveProgress(workId: workId, chapter: UInt32(highestChapter), position: storedPct)
        }
    }

    func resetProgress(_ id: String) {
        progressMap.removeValue(forKey: id)
        if let workId = UInt64(id) {
            bridge.deleteProgress(workId: workId)
        }
    }

    // MARK: - Subscriptions

    func loadSubscriptions(force: Bool = false) async {
        guard let username = ao3Username else {
            subscriptionError = "Sign in to AO3 in Settings first"
            return
        }
        guard !isLoadingSubscriptions else { return }

        let accountChanged = subscriptionsLoadedForAccount != username
        let shouldForce = force || accountChanged

        if !shouldForce {
            let persisted = bridge.getPersistedSubscriptions()
            if !persisted.isEmpty {
                subscriptions = persisted
                subscriptionsLoadedForAccount = username
                return
            }
            if let cached = bridge.getSessionCache(key: "subscriptions", sessionId: sessionId) {
                if let subs = decodeSubscriptions(cached) {
                    subscriptions = subs
                    subscriptionsLoadedForAccount = username
                    return
                }
            }
        }

        isLoadingSubscriptions = true
        subscriptionError = nil
        subscriptionLoadTask.reset()
        defer { isLoadingSubscriptions = false }

        do {
            subscriptions = try await retryOnTimeout(task: subscriptionLoadTask, using: bridge) {
                try await self.bridge.fetchSubscriptions(username: username)
            }
            subscriptionsLoadedForAccount = username
            try bridge.persistSubscriptions(subscriptions)
            if let json = encodeSubscriptions(subscriptions) {
                bridge.setSessionCache(key: "subscriptions", data: json, sessionId: sessionId)
            }
        } catch {
            if !subscriptionLoadTask.isCancelled && !"\(error)".contains("cancelled") {
                subscriptionError = Self.readableError(error)
            }
        }
    }

    private func encodeSubscriptions(_ subs: [USubscription]) -> String? {
        let arr: [[String: String]] = subs.map { ["subType": $0.subType, "id": $0.id, "name": $0.name] }
        guard let data = try? JSONSerialization.data(withJSONObject: arr) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private func decodeSubscriptions(_ json: String) -> [USubscription]? {
        guard let data = json.data(using: .utf8),
              let arr = try? JSONSerialization.jsonObject(with: data) as? [[String: String]] else { return nil }
        return arr.compactMap { dict -> USubscription? in
            guard let subType = dict["subType"], let id = dict["id"], let name = dict["name"] else { return nil }
            return USubscription(subType: subType, id: id, name: name)
        }
    }

    static func readableError(_ error: Error) -> String {
        if let ao3 = error as? Ao3Error {
            switch ao3 {
            case .Network(let message), .Parse(let message),
                 .Storage(let message), .NotFound(let message):
                return message
            }
        }
        return error.localizedDescription
    }

    func checkSubscriptions() async {
        guard ao3Username != nil else { return }
        guard !isCheckingSubscriptions else { return }
        isCheckingSubscriptions = true
        subscriptionCheckTask.reset()

        do {
            let total = try bridge.startSubscriptionCheck()
            subscriptionCheckTotal = Int(total)
            subscriptionCheckRemaining = Int(total)

            while !subscriptionCheckTask.isCancelled {
                guard let result = try await bridge.checkNextSubscription() else { break }
                subscriptionCheckRemaining = Int(result.remaining)
                if result.changed {
                    loadNewWorks()
                    reloadCachedWorks()
                }
            }

            // Also check inbox
            if !subscriptionCheckTask.isCancelled, let username = ao3Username {
                let inboxNotifications = try await bridge.checkInbox(username: username)
                if !inboxNotifications.isEmpty {
                    inboxUnreadCount += inboxNotifications.count
                }
                loadNotifications()
            }
        } catch {
            if !subscriptionCheckTask.isCancelled {
                subscriptionCheckTask.statusMessage = "Check failed: \(error.localizedDescription)"
            }
        }
        isCheckingSubscriptions = false
        subscriptionCheckTotal = 0
        subscriptionCheckRemaining = 0
    }

    func loadNewWorks() {
        newWorkIDs = bridge.getNewWorkIds().map { String($0) }
    }

    func removeNewWork(_ id: String) {
        if let workId = UInt64(id) {
            bridge.removeNewWork(workId)
        }
        newWorkIDs.removeAll { $0 == id }
    }

    func clearNewWorks() {
        bridge.clearNewWorks()
        newWorkIDs = []
    }

    private func reloadCachedWorks() {
        cachedWorks = bridge.getAllCachedWorks().map(Self.workFromSummary)
    }

    func loadNotifications() {
        notifications = bridge.getNotifications()
        unreadNotificationCount = Int(bridge.getUnreadNotificationCount())
    }

    func markNotificationRead(_ id: Int64) {
        bridge.markNotificationRead(id)
        loadNotifications()
    }

    func markAllNotificationsRead() {
        bridge.markAllNotificationsRead()
        loadNotifications()
    }

    // MARK: - Browse & Search

    var browseResults: [Work] = []
    var browseCurrentPage: UInt32 = 0
    var isBrowsing = false
    var searchCurrentPage: UInt32 = 0
    var lastSearchKeys: [String] = []
    var lastSearchValues: [String] = []

    func browseLatestWorks(force: Bool = false) async {
        guard !bridge.networkBlocked else { return }
        guard !isBrowsing else { return }

        // Load from cache on first page if not forcing
        if browseCurrentPage == 0 && !force {
            if let cached = bridge.getSessionCache(key: "browse", sessionId: sessionId),
               let works = Self.decodeWorks(cached) {
                browseResults = works
                browseCurrentPage = UInt32(max(1, works.count / 20))
                return
            }
        }

        isBrowsing = true
        searchError = nil
        let page = force ? 1 : browseCurrentPage + 1
        do {
            let results = try await retryOnTimeout(task: browseTask, using: bridge) {
                try await self.bridge.browseWorks(page: page)
            }
            let newWorks = results.map(Self.workFromSummary)
            if page == 1 {
                browseResults = newWorks
            } else {
                let existingIDs = Set(browseResults.map(\.id))
                let unique = newWorks.filter { !existingIDs.contains($0.id) }
                if !unique.isEmpty {
                    browseResults.append(contentsOf: unique)
                }
            }
            browseCurrentPage = page
            if let json = Self.encodeWorks(browseResults) {
                bridge.setSessionCache(key: "browse", data: json, sessionId: sessionId)
            }
        } catch {
            if !browseTask.isCancelled && !"\(error)".contains("cancelled") { searchError = error.localizedDescription }
        }
        isBrowsing = false
    }

    private var searchCacheKey: String {
        let paramStr = zip(lastSearchKeys, lastSearchValues).map { "\($0)=\($1)" }.sorted().joined(separator: "&")
        return "search_\(paramStr.hashValue)"
    }

    func searchAO3Raw(keys: [String], values: [String]) async {
        isSearching = true
        searchError = nil
        searchCurrentPage = 1
        lastSearchKeys = keys
        lastSearchValues = values
        do {
            let results = try await retryOnTimeout(task: searchTask, using: bridge) {
                try await self.bridge.searchWorksRaw(keys: keys, values: values, page: 1)
            }
            searchResults = results.map(Self.workFromSummary)
            if let json = Self.encodeWorks(searchResults) {
                bridge.setSessionCache(key: searchCacheKey, data: json, sessionId: sessionId)
            }
        } catch {
            if !searchTask.isCancelled && !"\(error)".contains("cancelled") { searchError = error.localizedDescription }
        }
        isSearching = false
    }

    func searchAO3More() async {
        guard !isSearching else { return }
        isSearching = true
        let page = searchCurrentPage + 1
        do {
            let results = try await retryOnTimeout(task: searchTask, using: bridge) {
                try await self.bridge.searchWorksRaw(keys: self.lastSearchKeys, values: self.lastSearchValues, page: UInt32(page))
            }
            let newWorks = results.map(Self.workFromSummary)
            let existingIDs = Set(searchResults.map(\.id))
            let unique = newWorks.filter { !existingIDs.contains($0.id) }
            searchResults.append(contentsOf: unique)
            searchCurrentPage = page
            if let json = Self.encodeWorks(searchResults) {
                bridge.setSessionCache(key: searchCacheKey, data: json, sessionId: sessionId)
            }
        } catch {
            if !searchTask.isCancelled && !"\(error)".contains("cancelled") { searchError = error.localizedDescription }
        }
        isSearching = false
    }

    func searchAO3(params: USearchParams) async {
        isSearching = true
        searchError = nil
        do {
            let results = try await retryOnTimeout(task: searchTask, using: bridge) {
                try await self.bridge.searchWorks(params)
            }
            searchResults = results.map(Self.workFromSummary)
        } catch {
            if !searchTask.isCancelled && !"\(error)".contains("cancelled") { searchError = error.localizedDescription }
        }
        isSearching = false
    }

    func searchAO3(tag: String) async {
        isSearching = true
        searchError = nil
        do {
            let results = try await retryOnTimeout(task: searchTask, using: bridge) {
                try await self.bridge.searchByTag(tag)
            }
            searchResults = results.map(Self.workFromSummary)
        } catch {
            if !searchTask.isCancelled && !"\(error)".contains("cancelled") { searchError = error.localizedDescription }
        }
        isSearching = false
    }

    static func workFromSummary(_ s: UWorkSummary) -> Work {
        Work(
            id: String(s.id),
            title: s.title,
            author: s.authors.first ?? "Unknown",
            fandom: s.fandoms.first ?? "Unknown Fandom",
            relationship: s.relationships.first ?? "",
            rating: ratingFromString(s.rating),
            warnings: s.warnings.first ?? "No Archive Warnings Apply",
            category: s.categories.first ?? "",
            tags: s.tags,
            words: Int(s.wordCount),
            chapterCount: Int(s.chapterCount),
            totalChapters: s.totalChapters > 0 ? Int(s.totalChapters) : Int(s.chapterCount),
            complete: s.complete,
            kudos: Int(s.kudos),
            hits: Int(s.hits),
            bookmarks: Int(s.bookmarksCount),
            comments: Int(s.comments),
            published: s.datePublished,
            updated: s.dateUpdated,
            summary: s.summary,
            initialProgress: 0,
            lastChapter: nil,
            downloaded: false,
            content: nil
        )
    }

    private static func ratingFromString(_ s: String) -> Rating {
        switch s {
        case "General": .general
        case "Teen": .teen
        case "Mature": .mature
        case "Explicit": .explicit
        default: .general
        }
    }

    // MARK: - Work Cache Serialization

    static func encodeWorks(_ works: [Work]) -> String? {
        let arr: [[String: Any]] = works.map { w in
            ["id": w.id, "title": w.title, "author": w.author, "fandom": w.fandom,
             "rating": w.rating.rawValue, "warnings": w.warnings, "tags": w.tags,
             "words": w.words, "chapterCount": w.chapterCount, "totalChapters": w.totalChapters,
             "complete": w.complete, "kudos": w.kudos, "hits": w.hits, "bookmarks": w.bookmarks,
             "comments": w.comments, "published": w.published, "updated": w.updated, "summary": w.summary,
             "relationship": w.relationship, "category": w.category]
        }
        guard let data = try? JSONSerialization.data(withJSONObject: arr) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func decodeWorks(_ json: String) -> [Work]? {
        guard let data = json.data(using: .utf8),
              let arr = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { return nil }
        let works = arr.compactMap { dict -> Work? in
            guard let id = dict["id"] as? String,
                  let title = dict["title"] as? String,
                  let author = dict["author"] as? String,
                  let fandom = dict["fandom"] as? String else { return nil }
            return Work(
                id: id, title: title, author: author, fandom: fandom,
                relationship: dict["relationship"] as? String ?? "",
                rating: ratingFromString(dict["rating"] as? String ?? "General"),
                warnings: dict["warnings"] as? String ?? "",
                category: dict["category"] as? String ?? "",
                tags: dict["tags"] as? [String] ?? [],
                words: dict["words"] as? Int ?? 0,
                chapterCount: dict["chapterCount"] as? Int ?? 0,
                totalChapters: dict["totalChapters"] as? Int ?? 0,
                complete: dict["complete"] as? Bool ?? false,
                kudos: dict["kudos"] as? Int ?? 0,
                hits: dict["hits"] as? Int ?? 0,
                bookmarks: dict["bookmarks"] as? Int ?? 0,
                comments: dict["comments"] as? Int ?? 0,
                published: dict["published"] as? String ?? "",
                updated: dict["updated"] as? String ?? "",
                summary: dict["summary"] as? String ?? "",
                initialProgress: 0, lastChapter: nil, downloaded: false, content: nil
            )
        }
        return works.isEmpty ? nil : works
    }
}
