import Foundation

extension RustBridge {
    // MARK: - Library-scoped search (cached data only, no network)

    func searchLibraryWorks(_ term: String, limit: UInt32? = nil) -> [UWorkSummary] {
        (try? app?.searchLibraryWorks(term: term, limit: limit)) ?? []
    }

    func searchLibraryWorksFiltered(_ criteria: ULibrarySearchCriteria,
                                    limit: UInt32? = nil) -> [UWorkSummary] {
        (try? app?.searchLibraryWorksFiltered(criteria: criteria, limit: limit)) ?? []
    }

    /// Run a library works search in the core (one SQL pass) and hold the
    /// result set there under a handle; pages hydrate via
    /// `getLibrarySearchPage`. nil = the search failed.
    func runLibrarySearch(_ criteria: ULibrarySearchCriteria) -> ULibrarySearch? {
        try? app?.runLibrarySearch(criteria: criteria)
    }

    /// One slice of a held search (len nil = through the end). Empty when
    /// the handle is gone — re-run the search for a fresh one.
    func getLibrarySearchPage(_ handle: UInt64, offset: UInt64 = 0,
                              len: UInt64? = nil) -> [UWorkSummary] {
        (try? app?.getLibrarySearchPage(handle: handle, offset: offset, len: len)) ?? []
    }

    /// Release a held search; dropping an already-gone handle is a no-op.
    func dropLibrarySearch(_ handle: UInt64) {
        app?.dropLibrarySearch(handle: handle)
    }

    func searchLibraryTags(_ term: String, limit: UInt32? = nil) -> [UTagHit] {
        (try? app?.searchLibraryTags(term: term, limit: limit)) ?? []
    }

    func searchLibraryUsers(_ term: String, limit: UInt32? = nil) -> [String] {
        (try? app?.searchLibraryUsers(term: term, limit: limit)) ?? []
    }

    func searchLibraryCollections(_ term: String, limit: UInt32? = nil) -> [UCollection] {
        (try? app?.searchLibraryCollections(term: term, limit: limit)) ?? []
    }

    /// The bookmark-search form evaluated against every cached bookmark
    /// row — full bookmark hits with the work blurb embedded; blank
    /// criteria return the whole cache.
    func searchLibraryBookmarksFiltered(_ criteria: UBookmarkSearchCriteria,
                                        limit: UInt32? = nil) -> [UBookmarkHit] {
        (try? app?.searchLibraryBookmarksFiltered(criteria: criteria, limit: limit)) ?? []
    }

    /// The collections sort/filter form evaluated against the cached
    /// collections — blank criteria return the whole cache.
    func searchLibraryCollectionsFiltered(_ criteria: UCollectionSearchCriteria,
                                          limit: UInt32? = nil) -> [UCollection] {
        (try? app?.searchLibraryCollectionsFiltered(criteria: criteria, limit: limit)) ?? []
    }

    /// The cached works seen in a collection's listing — the library-mode
    /// view of a collection's works, no network.
    func getLibraryCollectionWorks(name: String) -> [UWorkSummary] {
        (try? app?.getLibraryCollectionWorks(name: name)) ?? []
    }

    /// The cached bookmarks seen in a collection's /bookmarks listing — the
    /// library-mode view of its bookmarked items, no network.
    func getLibraryCollectionBookmarks(name: String) -> [UBookmarkHit] {
        (try? app?.getLibraryCollectionBookmarks(name: name)) ?? []
    }

    func checkNextFollow() async throws -> UFollowCheckResult? {
        guard let app else { throw BridgeError.notInitialized }
        return try await app.checkNextFollow()
    }

    func resetWhatsNewCheck() {
        try? app?.resetWhatsNewCheck()
    }

    func getNewWorkIds() -> [UInt64] {
        (try? app?.getNewWorkIds()) ?? []
    }

    func getUnseenNewWorkIds() -> [UInt64] {
        (try? app?.getUnseenNewWorkIds()) ?? []
    }

    func markNewWorkSeen(_ workId: UInt64) {
        try? app?.markNewWorkSeen(workId: workId)
    }

    /// Works a census confirmed are no longer listed on AO3 (cached copies
    /// are retained; this is display metadata).
    func markWorkDetailViewed(_ workId: UInt64) {
        try? app?.markWorkDetailViewed(workId: workId)
    }

    func markWorkRead(_ workId: UInt64) {
        try? app?.markWorkRead(workId: workId)
    }

    func getWorkLastReadTimes() -> [ULastRead] {
        (try? app?.getWorkLastReadTimes()) ?? []
    }

    func getDetailViewedWorkIds() -> [UInt64] {
        (try? app?.getDetailViewedWorkIds()) ?? []
    }

    func getGoneWorkIds() -> [UInt64] {
        (try? app?.getGoneWorkIds()) ?? []
    }

    func getFinishedWorkIds() -> [UInt64] {
        (try? app?.getFinishedWorkIds()) ?? []
    }

    func setWorksFinished(_ workIds: [UInt64], finished: Bool) {
        try? app?.setWorksFinished(workIds: workIds, finished: finished)
    }

    /// Cache-only lookup for a chapter-embedded image.
    func cachedChapterImage(url: String) -> Data? {
        guard let bytes = (try? app?.getCachedChapterImage(url: url)) ?? nil else { return nil }
        return Data(bytes)
    }

    /// Fetch a chapter-embedded image over the private connection
    /// (cache-first). maxBytes 0 = unlimited.
    func fetchChapterImage(url: String, maxBytes: UInt64) async throws -> Data {
        guard let app else { throw BridgeError.notInitialized }
        return try await Data(app.fetchChapterImage(url: url, maxBytes: maxBytes))
    }

    /// Prefetch all of a downloaded work's embedded images for offline
    /// reading. Failures and over-cap images are skipped, not fatal.
    func downloadWorkImages(workId: UInt64, maxBytes: UInt64) async {
        _ = try? await app?.downloadWorkImages(workId: workId, maxBytes: maxBytes)
    }

    /// Stamp "a full works crawl for this author/series completed now".
    func setWorksCrawledNow(kind: String, targetId: String) {
        try? app?.setWorksCrawledNow(kind: kind, targetId: targetId)
    }

    /// UTC datetime of the last completed works crawl, or nil.
    func getWorksCrawledAt(kind: String, targetId: String) -> String? {
        (try? app?.getWorksCrawledAt(kind: kind, targetId: targetId)) ?? nil
    }

    func removeNewWork(_ workId: UInt64) {
        try? app?.removeNewWork(workId: workId)
    }

    func clearNewWorks() {
        try? app?.clearNewWorks()
    }

    func checkInbox(username: String) async throws -> [UNotification] {
        guard let app else { throw BridgeError.notInitialized }
        return try await app.checkInbox(username: username)
    }

    func fetchInbox(username: String, page: UInt32) async throws -> String {
        guard let app else { throw BridgeError.notInitialized }
        return try await app.fetchInbox(username: username, page: page)
    }

    func getCachedInbox(page: UInt32) -> String {
        guard let app else { return "{}" }
        return (try? app.getCachedInbox(page: page)) ?? "{}"
    }

    /// The cached thread containing a comment; `thread` is null when it has
    /// never been fetched. No network.
    func getCachedCommentThread(commentId: UInt64) -> String {
        guard let app else { return "{}" }
        return (try? app.getCachedCommentThread(commentId: commentId)) ?? "{}"
    }

    /// Always a request to AO3 — the explicit refresh, or the first load of
    /// a thread not in the cache.
    func fetchCommentThread(workUrl: String, commentId: UInt64) async throws -> String {
        guard let app else { throw BridgeError.notInitialized }
        return try await app.fetchCommentThread(workUrl: workUrl, commentId: commentId)
    }

    func getNotifications() -> [UNotification] {
        (try? app?.getNotifications()) ?? []
    }

    func getUnreadNotificationCount() -> UInt32 {
        (try? app?.getUnreadNotificationCount()) ?? 0
    }

    func markNotificationRead(_ id: Int64) {
        try? app?.markNotificationRead(notificationId: id)
    }

    func markAllNotificationsRead() {
        try? app?.markAllNotificationsRead()
    }

    func clearReadNotifications() {
        try? app?.clearReadNotifications()
    }

    func getLastWhatsNewCheck() -> String? {
        try? app?.getLastWhatsNewCheck()
    }

    // MARK: - Community Actions

    /// Works this device has successfully left kudos on (persisted in Rust).
    func getKudosGiven() -> [UInt64] {
        (try? app?.getKudosGiven()) ?? []
    }

    func leaveKudos(workId: UInt64, opID: UInt64? = nil) async throws -> Bool {
        guard let app else { throw BridgeError.notInitialized }
        return try await app.leaveKudos(workId: workId, opId: opID)
    }

    func postComment(workId: UInt64, chapterId: UInt64, comment: String) async throws -> Bool {
        guard let app else { throw BridgeError.notInitialized }
        return try await app.postComment(workId: workId, chapterId: chapterId, comment: comment)
    }

    func postReply(parentCommentId: UInt64, comment: String) async throws -> Bool {
        guard let app else { throw BridgeError.notInitialized }
        return try await app.postReply(parentCommentId: parentCommentId, comment: comment)
    }

    func fetchChapterComments(workId: UInt64, chapterId: UInt64, page: UInt32) async throws -> UCommentsPage {
        guard let app else { throw BridgeError.notInitialized }
        return try await app.fetchChapterComments(workId: workId, chapterId: chapterId, page: page)
    }

    func fetchWorkComments(workId: UInt64, page: UInt32) async throws -> UCommentsPage {
        guard let app else { throw BridgeError.notInitialized }
        return try await app.fetchWorkComments(workId: workId, page: page)
    }

    func getCachedComments(workId: UInt64, chapterId: UInt64) -> String {
        guard let app else { return "[]" }
        return (try? app.getCachedComments(workId: workId, chapterId: chapterId)) ?? "[]"
    }

    func fetchImage(url: String) async throws -> Data {
        guard let app else { throw BridgeError.notInitialized }
        return Data(try await app.fetchImage(url: url))
    }

    enum BridgeError: Error, LocalizedError {
        case notInitialized

        var errorDescription: String? {
            switch self {
            case .notInitialized: "Rust backend not initialized"
            }
        }
    }
}
