import Foundation

extension RustBridge {
    // MARK: - Session Cache

    func setSessionCache(key: String, data: String, sessionId: String) {
        try? app?.setSessionCache(key: key, data: data, sessionId: sessionId)
    }

    func getSessionCache(key: String, sessionId: String) -> String? {
        (try? app?.getSessionCache(key: key, sessionId: sessionId)) ?? nil
    }

    func invalidateSessionCache(key: String) {
        try? app?.invalidateSessionCache(key: key)
    }

    func clearAllSessionCache() {
        try? app?.clearAllSessionCache()
    }

    // MARK: - Debug Log

    /// Newest `limit` rows, oldest first; 0 = every row.
    func getLogs(limit: UInt32 = 0) -> [ULogEntry] {
        (try? app?.getLogs(limit: limit)) ?? []
    }

    /// `getLogs` as text; 0 = every row.
    func dumpLogs(limit: UInt32 = 0) -> String {
        (try? app?.dumpLogs(limit: limit)) ?? ""
    }

    func clearLogs() {
        try? app?.clearLogs()
    }

    /// One page of the log: rows matching `query` with ids strictly between
    /// `afterID` and `beforeID` (0 = unbounded), newest first, at most
    /// `limit` (0 = all).
    func queryLogs(_ query: ULogQuery, beforeID: Int64 = 0, afterID: Int64 = 0, limit: UInt32 = 0) -> [ULogEntry] {
        (try? app?.queryLogs(query: query, beforeId: beforeID, afterId: afterID, limit: limit)) ?? []
    }

    func countLogs(_ query: ULogQuery) -> UInt64 {
        app?.countLogs(query: query) ?? 0
    }

    func logTags() -> [String] {
        app?.logTags() ?? []
    }

    func writeLog(level: String, tag: String, message: String) {
        try? app?.writeLog(level: level, tag: tag, message: message)
    }

    // MARK: - Request Audit Log

    func getRequestLog(limit: UInt32 = 500) -> [URequestLogEntry] {
        (try? app?.getRequestLog(limit: limit)) ?? []
    }

    /// Requests currently in flight (for the request log's live view).
    func getActiveRequests() -> [UActiveRequest] {
        app?.getActiveRequests() ?? []
    }

    /// Cached avatar bytes (sync, DB-only).
    func getCachedAuthorAvatar(_ username: String) -> Data? {
        (try? app?.getCachedAuthorAvatar(username: username)) ?? nil
    }

    /// Avatar bytes — cache-first; fetches from AO3 once and caches forever.
    /// A URL hint (from inbox/comment data) skips the profile-page scrape.
    func fetchAuthorAvatar(_ username: String, urlHint: String? = nil) async throws -> Data {
        guard let app else { throw BridgeError.notInitialized }
        return try await app.fetchAuthorAvatar(username: username, urlHint: urlHint)
    }

    /// Local tag autocomplete — instant, DB-only, never touches the network.
    func searchLocalTags(tagType: String, term: String, limit: UInt32 = 12) -> [String] {
        (try? app?.searchLocalTags(tagType: tagType, term: term, limit: limit)) ?? []
    }

    /// Explicit AO3 autocomplete lookup; results are cached as canonical.
    func autocompleteTagsRemote(tagType: String, term: String) async throws -> [String] {
        guard let app else { throw BridgeError.notInitialized }
        return try await app.autocompleteTagsRemote(tagType: tagType, term: term)
    }

    /// Export a downloaded work as an EPUB3 file at `path`.
    func exportEpub(workId: UInt64, path: String) throws {
        guard let app else { throw BridgeError.notInitialized }
        try app.exportEpub(workId: workId, destPath: path)
    }

    func clearRequestLog() {
        try? app?.clearRequestLog()
    }

    // MARK: - Subscription Notifications

    /// Reload the signed-in account's subscription list from AO3 and store
    /// it. Subscription data only — follows are never touched.
    func syncSubscriptions() async throws -> [USubscription] {
        guard let app else { throw BridgeError.notInitialized }
        return try await app.syncSubscriptions()
    }

    /// The signed-in account's stored subscriptions (empty when signed out).
    func getPersistedSubscriptions() -> [USubscription] {
        (try? app?.getPersistedSubscriptions()) ?? []
    }

    /// Every cached bookmark attributed to a user (works and series),
    /// newest first — the library-mode view of their public bookmarks.
    func getLibraryUserBookmarks(username: String) -> [UBookmarkHit] {
        (try? app?.getLibraryUserBookmarks(username: username)) ?? []
    }

    func getSubscriptionWorks(subType: String, subId: String) -> [UWorkSummary] {
        (try? app?.getSubscriptionWorks(subType: subType, subId: subId)) ?? []
    }

    func getWorksByAuthor(username: String) -> [UWorkSummary] {
        (try? app?.getWorksByAuthor(username: username)) ?? []
    }

    // MARK: - What's New check (follows only)

    /// `olderThanSecs` limits the round to follows last checked longer ago
    /// than that, or never; nil leaves `onlyStale` in charge.
    func startWhatsNewCheck(onlyStale: Bool, olderThanSecs: UInt64? = nil) throws -> UInt32 {
        guard let app else { throw BridgeError.notInitialized }
        return try app.startWhatsNewCheck(onlyStale: onlyStale, olderThanSecs: olderThanSecs)
    }

    /// The persisted What's New queue, front item first.
    func getWhatsNewCheckQueue() -> [UCheckQueueItem] {
        (try? app?.getWhatsNewCheckQueue()) ?? []
    }

    /// True when any checked follow's own last-checked stamp is missing or
    /// stale, or leftover queue items exist.
    func isWhatsNewCheckDue() -> Bool {
        (try? app?.isWhatsNewCheckDue()) ?? false
    }

    /// How many checked follows were last checked over `maxAgeSecs` ago,
    /// or never; nil when the library isn't readable.
    func whatsNewOverdue(maxAgeSecs: UInt64) -> UWhatsNewOverdue? {
        try? app?.whatsNewOverdue(maxAgeSecs: maxAgeSecs)
    }
}
