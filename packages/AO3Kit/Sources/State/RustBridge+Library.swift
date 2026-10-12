import Foundation

extension RustBridge {
    // MARK: - Cache

    func markDownloaded(_ workId: UInt64) {
        try? app?.markDownloaded(workId: workId)
    }

    func unmarkDownloaded(_ workId: UInt64) {
        try? app?.unmarkDownloaded(workId: workId)
    }

    func getDownloadedIds() -> [UInt64] {
        (try? app?.getDownloadedIds()) ?? []
    }

    func setCurrentWork(_ workId: UInt64) {
        try? app?.setCurrentWork(workId: workId)
    }

    func getCurrentWork() -> UInt64? {
        try? app?.getCurrentWork()
    }

    func purgeStaleChapters() {
        try? app?.purgeStaleChapters()
    }

    func saveSearch(name: String, paramsJson: String) {
        guard let app else {
            NSLog("[saved-search] saveSearch(%@): app is nil (runtime not initialized)", name)
            return
        }
        do {
            try app.saveSearch(name: name, paramsJson: paramsJson)
            NSLog("[saved-search] saveSearch(%@): ok", name)
        } catch {
            NSLog("[saved-search] saveSearch(%@) failed: %@", name, String(describing: error))
        }
    }

    func getSavedSearches() -> [USavedSearch] {
        guard let app else {
            NSLog("[saved-search] getSavedSearches: app is nil (runtime not initialized)")
            return []
        }
        do {
            let saved = try app.getSavedSearches()
            NSLog("[saved-search] getSavedSearches: %d row(s)", saved.count)
            return saved
        } catch {
            NSLog("[saved-search] getSavedSearches failed: %@", String(describing: error))
            return []
        }
    }

    func deleteSavedSearch(_ id: Int64) {
        try? app?.deleteSavedSearch(searchId: id)
    }

    // MARK: - Custom Themes

    func saveCustomTheme(id: String, name: String, json: String) {
        try? app?.saveCustomTheme(id: id, name: name, json: json)
    }

    func getCustomThemes() -> [UCustomTheme] {
        (try? app?.getCustomThemes()) ?? []
    }

    func deleteCustomTheme(id: String) {
        try? app?.deleteCustomTheme(id: id)
    }

    // MARK: - Reading Lists

    func createReadingList(_ name: String) -> Int64 {
        (try? app?.createReadingList(name: name)) ?? -1
    }

    func renameReadingList(_ listId: Int64, name: String) {
        try? app?.renameReadingList(listId: listId, name: name)
    }

    func deleteReadingList(_ listId: Int64) {
        try? app?.deleteReadingList(listId: listId)
    }

    func getReadingLists() -> [UReadingList] {
        (try? app?.getReadingLists()) ?? []
    }

    func addToReadingList(_ listId: Int64, workId: UInt64) {
        try? app?.addToReadingList(listId: listId, workId: workId)
    }

    func removeFromReadingList(_ listId: Int64, workId: UInt64) {
        try? app?.removeFromReadingList(listId: listId, workId: workId)
    }

    func getReadingListItems(_ listId: Int64) -> [UInt64] {
        (try? app?.getReadingListItems(listId: listId)) ?? []
    }

    func getReadingListsForWork(_ workId: UInt64) -> [Int64] {
        (try? app?.getReadingListsForWork(workId: workId)) ?? []
    }

    func getAllCachedWorks() -> [UWorkSummary] {
        (try? app?.getAllCachedWorks()) ?? []
    }

    func getAllProgress() -> [UReadingProgress] {
        (try? app?.getAllProgress()) ?? []
    }

    func getCachedWork(_ workId: UInt64) -> UWorkSummary? {
        try? app?.getCachedWork(workId: workId)
    }

    func getCachedChapters(_ workId: UInt64) -> [UChapter] {
        (try? app?.getCachedChapters(workId: workId)) ?? []
    }

    // MARK: - Bookmarks

    func addBookmark(_ workId: UInt64, note: String? = nil, syncToAo3: Bool = false) {
        try? app?.addBookmark(workId: workId, note: note, syncToAo3: syncToAo3)
    }

    func removeBookmark(_ workId: UInt64) {
        try? app?.removeBookmark(workId: workId)
    }

    func isBookmarked(_ workId: UInt64) -> Bool {
        (try? app?.isBookmarked(workId: workId)) ?? false
    }

    func getBookmarkedWorkIds() -> [UInt64] {
        (try? app?.getBookmarkedWorkIds()) ?? []
    }

    // Series bookmarks — the series twins of the work-keyed calls above.
    // A series must be cached (a series bookmark blurb fetched it) before
    // it can be bookmarked.

    func addSeriesBookmark(_ seriesId: UInt64, note: String? = nil, syncToAo3: Bool = false) {
        try? app?.addSeriesBookmark(seriesId: seriesId, note: note, syncToAo3: syncToAo3)
    }

    func removeSeriesBookmark(_ seriesId: UInt64) {
        try? app?.removeSeriesBookmark(seriesId: seriesId)
    }

    func isSeriesBookmarked(_ seriesId: UInt64) -> Bool {
        (try? app?.isSeriesBookmarked(seriesId: seriesId)) ?? false
    }

    func getBookmarkedSeriesIds() -> [UInt64] {
        (try? app?.getBookmarkedSeriesIds()) ?? []
    }

    func getSeriesBookmarkDetails(_ seriesId: UInt64) -> UBookmarkDetails? {
        (try? app?.getSeriesBookmarkDetails(seriesId: seriesId)) ?? nil
    }

    func updateSeriesBookmarkDetails(_ seriesId: UInt64, note: String, tagString: String,
                                     collectionNames: String, private isPrivate: Bool, rec: Bool) {
        try? app?.updateSeriesBookmarkDetails(seriesId: seriesId, note: note, tagString: tagString,
                                              collectionNames: collectionNames, private: isPrivate, rec: rec)
    }

    func updateSeriesBookmarkSync(_ seriesId: UInt64, sync: Bool) {
        try? app?.updateSeriesBookmarkSync(seriesId: seriesId, sync: sync)
    }

    func pushSeriesBookmark(seriesId: UInt64) async throws -> Bool {
        guard let app else { throw BridgeError.notInitialized }
        return try await app.pushSeriesBookmark(seriesId: seriesId)
    }

    func deleteAo3SeriesBookmark(seriesId: UInt64) async throws -> Bool {
        guard let app else { throw BridgeError.notInitialized }
        return try await app.deleteAo3SeriesBookmark(seriesId: seriesId)
    }

    func getCachedSeries(_ seriesId: UInt64) -> USeriesSummary? {
        (try? app?.getCachedSeries(seriesId: seriesId)) ?? nil
    }

    // MARK: - Progress

    func saveProgress(workId: UInt64, chapter: UInt32, position: UInt32) {
        try? app?.saveProgress(workId: workId, chapter: chapter, position: position)
    }

    func getProgress(_ workId: UInt64) -> UReadingProgress? {
        try? app?.getProgress(workId: workId)
    }

    func deleteProgress(workId: UInt64) {
        try? app?.deleteProgress(workId: workId)
    }

    // MARK: - History

    func addToHistory(_ workId: UInt64) {
        try? app?.addToHistory(workId: workId)
    }

    func getHistory() -> [UHistoryEntry] {
        (try? app?.getHistory()) ?? []
    }

    func clearHistory() {
        try? app?.clearHistory()
    }

    // MARK: - Paths

    nonisolated static func databasePath() -> String {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let appDir = dir.appendingPathComponent("ArchiveOfYourOwn", isDirectory: true)
        try? FileManager.default.createDirectory(at: appDir, withIntermediateDirectories: true)
        return appDir.appendingPathComponent("library.db").path
    }
}
