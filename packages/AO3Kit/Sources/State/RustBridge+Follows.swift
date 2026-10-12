import Foundation

extension RustBridge {
    // MARK: - Prefs, follows & work-list compute (Rust-owned state/logic)

    /// True once the encrypted DB is open — prefs and follows can load.
    var isDatabaseOpen: Bool { app != nil }

    func setPref(key: String, value: String) {
        try? app?.setPref(key: key, value: value)
    }

    func getPref(key: String) -> String? {
        (try? app?.getPref(key: key)) ?? nil
    }

    // MARK: - Follows

    /// Follows of `kind` (every kind when nil), in the order they were added.
    func getFollows(kind: String? = nil) -> [UFollow] {
        (try? app?.getFollows(kind: kind)) ?? []
    }

    /// Local follow — never an AO3 request. True when newly created.
    @discardableResult
    func addFollow(kind: String, targetId: String, name: String) -> Bool {
        (try? app?.addFollow(kind: kind, targetId: targetId, name: name)) ?? false
    }

    /// Local unfollow. Throws while the signed-in account is subscribed to
    /// the target — that change goes through `applyFollowChange`.
    @discardableResult
    func removeFollow(kind: String, targetId: String) throws -> Bool {
        guard let app else { throw BridgeError.notInitialized }
        return try app.removeFollow(kind: kind, targetId: targetId)
    }

    /// A confirmed bell-menu change: bring the target to exactly
    /// (followed, subscribed). AO3 request first; nothing local changes
    /// when it fails.
    func applyFollowChange(kind: String, targetId: String, name: String,
                           followed: Bool, subscribed: Bool) async throws -> UFollowChange {
        guard let app else { throw BridgeError.notInitialized }
        return try await app.applyFollowChange(kind: kind, targetId: targetId, name: name,
                                               wantFollowed: followed, wantSubscribed: subscribed)
    }

    /// The signed-in account's subscriptions with no follow.
    func getUnfollowedSubscriptions() -> [USubscription] {
        (try? app?.getUnfollowedSubscriptions()) ?? []
    }

    /// Follow every given subscription's target (one transaction, no AO3
    /// request). Returns how many follows were created.
    func followSubscriptions(_ subscriptions: [USubscription]) throws -> Int {
        guard let app else { throw BridgeError.notInitialized }
        return Int(try app.followSubscriptions(subscriptions: subscriptions))
    }

    // MARK: - iCloud library sync + backups (CloudLibrarySync is the transport)

    func cloudSyncStatus() -> UCloudSyncStatus? {
        (try? app?.cloudSyncStatus()) ?? nil
    }

    func setCloudSyncEnabled(_ enabled: Bool) {
        try? app?.setCloudSyncEnabled(enabled: enabled)
    }

    func cloudSyncEvaluate(manifestJson: String?) throws -> UCloudVerdict? {
        try app?.cloudSyncEvaluate(manifestJson: manifestJson)
    }

    func cloudSyncExport(stagingPath: String, cloudKey: String, deviceName: String) throws -> UCloudExport? {
        try app?.cloudSyncExport(stagingPath: stagingPath, cloudKey: cloudKey, deviceName: deviceName)
    }

    func cloudSyncMarkPushed(generation: Int64) {
        try? app?.cloudSyncMarkPushed(generation: generation)
    }

    func cloudSyncDismiss(generation: Int64) {
        try? app?.cloudSyncDismiss(generation: generation)
    }

    func cloudSyncAdopt(stagedPath: String, cloudKey: String, expectedGeneration: Int64) throws -> UBackupInfo? {
        try app?.cloudSyncAdopt(stagedPath: stagedPath, cloudKey: cloudKey, expectedGeneration: expectedGeneration)
    }

    func cloudSyncStashForeignCopy(stagedPath: String, cloudKey: String, expectedGeneration: Int64) throws -> UBackupInfo? {
        try app?.cloudSyncStashForeignCopy(stagedPath: stagedPath, cloudKey: cloudKey, expectedGeneration: expectedGeneration)
    }

    func backupsList() -> [UBackupInfo] {
        (try? app?.backupsList()) ?? []
    }

    func backupRestore(id: String) throws -> UBackupInfo? {
        try app?.backupRestore(id: id)
    }

    func backupDelete(id: String) throws {
        try app?.backupDelete(id: id)
    }

    /// Directory the core keeps its files in (database, sync sidecar,
    /// Backups/) — where the transport stages files for it.
    nonisolated static func stateDirectory() -> URL {
        URL(fileURLWithPath: databasePath()).deletingLastPathComponent()
    }

    /// Rust-side filter/sort of a section's work list; falls back to the
    /// caller's order if the DB isn't open.
    func filterAndSortWorks(ids: [UInt64], query: UWorkListQuery) -> [UInt64] {
        (try? app?.filterAndSortWorks(workIds: ids, query: query)) ?? ids
    }

    func workFilterOptions(ids: [UInt64], query: UWorkListQuery) -> UWorkFilterOptions {
        (try? app?.workFilterOptions(workIds: ids, query: query))
            ?? UWorkFilterOptions(tags: [], fandoms: [])
    }

    func setCachedWorkList(key: String, sessionId: String, ids: [UInt64]) {
        try? app?.setCachedWorkList(key: key, sessionId: sessionId, workIds: ids)
    }

    func getCachedWorkList(key: String, sessionId: String) -> [UWorkSummary]? {
        (try? app?.getCachedWorkList(key: key, sessionId: sessionId)) ?? nil
    }
}
