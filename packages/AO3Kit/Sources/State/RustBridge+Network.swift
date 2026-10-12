import Foundation

extension RustBridge {
    // MARK: - Network

    func cancelRequest() {
        app?.cancelRequest()
    }

    /// Abort only the task(s) behind one tracked operation id — the
    /// per-surface counterpart of `cancelRequest`, which aborts everything.
    func cancelOperation(_ opID: UInt64) {
        app?.cancelOperation(opId: opID)
    }

    /// Every operation the recovery engine currently has in flight or is
    /// actively recovering — the authoritative snapshot a view asks for on
    /// mount instead of replaying events it may have missed.
    func activeOperations() -> [OperationStatus] {
        app?.activeOperations() ?? []
    }

    func setRequestTimeout(_ seconds: UInt64) {
        app?.setRequestTimeout(seconds: seconds)
    }

    /// The per-route timeout catalog: every request shape the app makes,
    /// with its current override (nil = follows the global timeout).
    func getRouteTimeouts() -> [URouteTimeout] {
        app?.getRouteTimeouts() ?? []
    }

    /// Set (positive seconds) or clear (nil) one route's timeout override.
    func setRouteTimeout(key: String, seconds: UInt64?) {
        try? app?.setRouteTimeout(key: key, timeoutSecs: seconds)
    }

    func getRequestTimeout() -> UInt64 {
        app?.getRequestTimeout() ?? 30
    }

    func fetchSearchForm() async throws -> [UFormField] {
        guard let app else { throw BridgeError.notInitialized }
        return try await app.fetchSearchForm()
    }

    func fetchAuthorWorks(username: String, pseud: String? = nil, page: UInt32 = 1,
                          opID: UInt64? = nil) async throws -> UPagedWorks {
        guard let app else { throw BridgeError.notInitialized }
        return try await app.fetchAuthorWorks(username: username, pseud: pseud, page: page, opId: opID)
    }

    /// One page of a user's public bookmarks — the targets (works and
    /// series) and bookmarker-scoped bookmark rows are cached by the core.
    func fetchUserBookmarksPage(username: String, page: UInt32 = 1,
                                opID: UInt64? = nil) async throws -> UPagedBookmarks {
        guard let app else { throw BridgeError.notInitialized }
        return try await app.fetchUserBookmarksPage(username: username, page: page, opId: opID)
    }

    /// One page of a user's collections — blurbs (tags included) are cached
    /// by the core like the public index.
    func fetchUserCollections(username: String, page: UInt32 = 1) async throws -> UCollectionsPage {
        guard let app else { throw BridgeError.notInitialized }
        return try await app.fetchUserCollections(username: username, page: page)
    }

    func fetchSeriesWorksPaged(seriesId: UInt64, page: UInt32 = 1,
                               opID: UInt64? = nil) async throws -> UPagedWorks {
        guard let app else { throw BridgeError.notInitialized }
        return try await app.fetchSeriesWorksPaged(seriesId: seriesId, page: page, opId: opID)
    }

    func browseWorks(page: UInt32 = 1) async throws -> [UWorkSummary] {
        guard let app else { throw BridgeError.notInitialized }
        return try await app.browseWorks(page: page)
    }

    func searchWorks(_ params: USearchParams, page: UInt32 = 1) async throws -> [UWorkSummary] {
        guard let app else { throw BridgeError.notInitialized }
        return try await app.searchWorks(params: params, page: page)
    }

    /// Paged variant: real has-next/total-pages read from the results HTML.
    func searchWorksRawPaged(keys: [String], values: [String], page: UInt32 = 1,
                             opID: UInt64? = nil) async throws -> UPagedWorks {
        guard let app else { throw BridgeError.notInitialized }
        return try await app.searchWorksRaw(keys: keys, values: values, page: page, opId: opID)
    }

    /// Paged variant of searchByTag.
    func searchByTagPaged(_ tag: String, page: UInt32 = 1,
                          opID: UInt64? = nil) async throws -> UPagedWorks {
        guard let app else { throw BridgeError.notInitialized }
        return try await app.searchByTag(tag: tag, page: page, opId: opID)
    }

    /// One page of AO3's /bookmarks/search under the form's criteria —
    /// full bookmark hits (bookmarker, tags, note, rec, date) with the
    /// work blurb embedded. Results are cached like every listing (works +
    /// bookmark rows).
    func searchBookmarks(criteria: UBookmarkSearchCriteria, page: UInt32 = 1,
                         opID: UInt64? = nil) async throws -> UPagedBookmarks {
        guard let app else { throw BridgeError.notInitialized }
        return try await app.searchBookmarks(criteria: criteria, page: page, opId: opID)
    }

    /// One page of the AO3 /collections index, optionally sorted/filtered
    /// with the index's collection_search criteria (nil = the plain index).
    func browseCollections(criteria: UCollectionSearchCriteria? = nil,
                           page: UInt32 = 1, opID: UInt64? = nil) async throws -> UCollectionsPage {
        guard let app else { throw BridgeError.notInitialized }
        return try await app.browseCollections(criteria: criteria, page: page, opId: opID)
    }

    /// One page of a collection's works. `name` is the collection's URL slug.
    func fetchCollectionWorks(name: String, page: UInt32 = 1,
                              opID: UInt64? = nil) async throws -> UPagedWorks {
        guard let app else { throw BridgeError.notInitialized }
        return try await app.fetchCollectionWorks(name: name, page: page, opId: opID)
    }

    /// One page of a collection's bookmarked items (works and series;
    /// external bookmarks are skipped).
    func fetchCollectionBookmarks(name: String, page: UInt32 = 1,
                                  opID: UInt64? = nil) async throws -> UPagedBookmarks {
        guard let app else { throw BridgeError.notInitialized }
        return try await app.fetchCollectionBookmarks(name: name, page: page, opId: opID)
    }

    /// The collection's /profile metadata and tags — fetched once, answered
    /// from the cache forever after.
    func ensureCollectionProfile(name: String) async throws -> UCollection {
        guard let app else { throw BridgeError.notInitialized }
        return try await app.ensureCollectionProfile(name: name)
    }

    func searchWorksRaw(keys: [String], values: [String], page: UInt32 = 1) async throws -> [UWorkSummary] {
        try await searchWorksRawPaged(keys: keys, values: values, page: page).works
    }

    func searchByTag(_ tag: String, page: UInt32 = 1) async throws -> [UWorkSummary] {
        try await searchByTagPaged(tag, page: page).works
    }

    /// Allocate an operation id for a UI-initiated call — the identifier
    /// half of the request-tracking standard. Pass it to a tracking-aware
    /// fetch (e.g. `fetchWork(_:opID:)`); every request the operation
    /// makes (retries included) and every CoreEvent it emits carries the
    /// id, so the initiating view can filter for exactly its own traffic.
    /// 0 = database not open (nothing to track anyway).
    func newOperationID() -> UInt64 {
        app?.newOperationId() ?? 0
    }

    func fetchWorkFull(_ workId: UInt64, opID: UInt64? = nil) async throws -> UWorkSummary {
        guard let app else { throw BridgeError.notInitialized }
        return try await app.fetchWorkFull(workId: workId, opId: opID)
    }

    func fetchWork(_ workId: UInt64, opID: UInt64? = nil) async throws -> UWorkSummary {
        guard let app else { throw BridgeError.notInitialized }
        return try await app.fetchWork(workId: workId, opId: opID)
    }

    func fetchChapters(_ workId: UInt64, opID: UInt64? = nil) async throws -> [UChapter] {
        guard let app else { throw BridgeError.notInitialized }
        return try await app.fetchChapters(workId: workId, opId: opID)
    }
}
