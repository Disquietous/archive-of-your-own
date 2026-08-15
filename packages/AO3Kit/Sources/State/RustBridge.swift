import Foundation

enum TorStatus: Equatable {
    case disconnected
    case connecting
    case connected
    case error(String)

    var displayText: String {
        switch self {
        case .disconnected: "Not connected"
        case .connecting: "Connecting…"
        case .connected: "Connected"
        case .error(let msg): "Error: \(msg)"
        }
    }

    var isConnected: Bool {
        self == .connected
    }
}

@Observable
final class RustBridge {
    private var app: Ao3App?
    var isInitialized = false
    var showingRecoveryKey = false
    var torStatus: TorStatus = .disconnected
    var connectionError: String?

    private var torOnlyApp: Ao3App?
    var torHasConnectedOnce = false
    var cloudflareReady = false

    // Connection-recovery hooks (AppState+Recovery.swift). Set once by
    // AppState before the first app instance exists; re-applied to every
    // `Ao3App`/tor-only bootstrap instance this bridge creates, since each
    // is a separate object Rust-side with its own observer/capability slot.
    var recoveryObserver: CoreObserver?
    var recoveryCapabilities: PlatformCapabilities?

    private func registerRecoveryHooks() {
        app?.setObserver(observer: recoveryObserver)
        app?.setPlatformCapabilities(capabilities: recoveryCapabilities)
        torOnlyApp?.setObserver(observer: recoveryObserver)
        torOnlyApp?.setPlatformCapabilities(capabilities: recoveryCapabilities)
    }

    var torRequired: Bool {
        UserDefaults.standard.bool(forKey: "useTorByDefault")
    }

    var networkBlocked: Bool {
        torRequired && !torStatus.isConnected
    }

    static var dbFileExists: Bool {
        FileManager.default.fileExists(atPath: databasePath())
    }

    enum LaunchState {
        case firstLaunch
        case locked
        case autoUnlock
        case connectingTor
        case ready
    }

    var launchState: LaunchState {
        if !Self.dbFileExists { return .firstLaunch }
        if !isInitialized && hasDbPassword { return .locked }
        if !isInitialized { return .autoUnlock }
        if showingRecoveryKey { return .firstLaunch }
        let torRequired = UserDefaults.standard.bool(forKey: "useTorByDefault")
        if torRequired && (!torHasConnectedOnce || !cloudflareReady) { return .connectingTor }
        return .ready
    }

    // MARK: - Database Operations

    /// Open an existing database. For user-password DBs, pass the user's password.
    /// For auto-key DBs, pass nil to use the Keychain key.
    func open(userPassword: String? = nil) -> Bool {
        guard let key = userPassword ?? Self.autoKey() else {
            connectionError = "Could not read the database key from the Keychain. Grant keychain access and relaunch."
            return false
        }
        let dbPath = Self.databasePath()
        do {
            // A tor-only holder (pre-unlock bootstrap, or a lock that kept
            // the circuit alive) hands its transport to the real runtime —
            // no re-bootstrap. Only cleared on success: a wrong password
            // must not cost the circuit.
            if let carrier = torOnlyApp {
                app = try Ao3App.withTransportFrom(previous: carrier, dbPath: dbPath, dbPassphrase: key)
            } else {
                app = try Ao3App(dbPath: dbPath, dbPassphrase: key)
            }
            torOnlyApp = nil
            isInitialized = true
            connectionError = nil
            registerRecoveryHooks()
            return true
        } catch {
            connectionError = error.localizedDescription
            return false
        }
    }

    /// Lock the library: persist session cookies, move the live transport
    /// (Tor circuit, cookie jar) into a tor-only holder on a throwaway
    /// database, then drop the runtime — the SQLCipher key material goes
    /// with it and launchState returns to .locked, which sends the window
    /// back to the unlock gate. The circuit survives the lock, so unlocking
    /// doesn't re-bootstrap Tor. Only meaningful for password-protected
    /// libraries (an auto-key DB would simply reopen itself).
    func lock() {
        guard hasDbPassword, isInitialized else { return }
        saveSessionCookies()
        if let app {
            let tempPath = Self.databasePath() + ".tor-temp"
            try? FileManager.default.removeItem(atPath: tempPath)
            try? FileManager.default.removeItem(atPath: tempPath + "-wal")
            try? FileManager.default.removeItem(atPath: tempPath + "-shm")
            torOnlyApp = try? Ao3App.withTransportFrom(previous: app, dbPath: tempPath, dbPassphrase: UUID().uuidString)
            registerRecoveryHooks()
        }
        app = nil
        isInitialized = false
        if torOnlyApp == nil {
            // Transport hand-off failed — fall back to the full teardown.
            torStatus = .disconnected
            torHasConnectedOnce = false
            cloudflareReady = false
            circuitHops = []
        }
    }

    /// Create a new database with a user-chosen password.
    func createWithPassword(_ password: String) -> Bool {
        let dbPath = Self.databasePath()
        // Remove any leftover file
        try? FileManager.default.removeItem(atPath: dbPath)
        try? FileManager.default.removeItem(atPath: dbPath + "-wal")
        try? FileManager.default.removeItem(atPath: dbPath + "-shm")
        do {
            app = try Ao3App(dbPath: dbPath, dbPassphrase: password)
            torOnlyApp = nil
            isInitialized = true
            connectionError = nil
            hasDbPassword = true
            Self.persistDbPasswordFlag(true)
            // Remove any auto-key since user owns the password now
            Self.deleteAutoKey()
            registerRecoveryHooks()
            return true
        } catch {
            connectionError = error.localizedDescription
            return false
        }
    }

    /// Create a new database with an auto-generated key (no user password).
    func createWithAutoKey() -> Bool {
        let key = Self.generateAndStoreAutoKey()
        let dbPath = Self.databasePath()
        try? FileManager.default.removeItem(atPath: dbPath)
        try? FileManager.default.removeItem(atPath: dbPath + "-wal")
        try? FileManager.default.removeItem(atPath: dbPath + "-shm")
        do {
            app = try Ao3App(dbPath: dbPath, dbPassphrase: key)
            torOnlyApp = nil
            isInitialized = true
            connectionError = nil
            hasDbPassword = false
            Self.persistDbPasswordFlag(false)
            registerRecoveryHooks()
            return true
        } catch {
            connectionError = error.localizedDescription
            return false
        }
    }

    /// Change password on an already-open database (PRAGMA rekey).
    func changePassword(to newPassword: String) -> Bool {
        guard let app else { return false }
        do {
            try app.changeDbPassword(newPassword: newPassword)
            hasDbPassword = true
            Self.persistDbPasswordFlag(true)
            Self.deleteAutoKey()
            return true
        } catch {
            connectionError = "\(error)"
            return false
        }
    }

    /// Remove user password — rekey to a new auto-generated key.
    func removePassword() -> Bool {
        guard let app else { return false }
        let newKey = Self.generateAndStoreAutoKey()
        do {
            try app.changeDbPassword(newPassword: newKey)
            hasDbPassword = false
            Self.persistDbPasswordFlag(false)
            return true
        } catch {
            connectionError = "\(error)"
            return false
        }
    }

    /// Verify a password by trying to open the DB file with it.
    func verifyPassword(_ password: String) -> Bool {
        let dbPath = Self.databasePath()
        do {
            let testApp = try Ao3App(dbPath: dbPath, dbPassphrase: password)
            // If it opened successfully, the password is correct.
            // We don't keep this instance — just testing.
            _ = testApp
            return true
        } catch {
            return false
        }
    }

    // MARK: - Auto Key (Keychain)

    private static let autoKeyAccount = "ao3_auto_db_key"

    private static func autoKey() -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: autoKeyAccount,
            kSecReturnData as String: true,
        ]
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecSuccess,
           let data = result as? Data,
           let key = String(data: data, encoding: .utf8) {
            return key
        }
        // Only mint a new key when none exists. Any other failure (access
        // denied, keychain locked) must NOT regenerate — replacing the key
        // would permanently orphan the existing encrypted database.
        if status == errSecItemNotFound {
            return generateAndStoreAutoKey()
        }
        return nil
    }

    private static func generateAndStoreAutoKey() -> String {
        deleteAutoKey()
        let key = UUID().uuidString + "-" + UUID().uuidString
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: autoKeyAccount,
            kSecValueData as String: key.data(using: .utf8)!,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
        ]
        SecItemAdd(query as CFDictionary, nil)
        return key
    }

    private static func deleteAutoKey() {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: autoKeyAccount,
        ]
        SecItemDelete(query as CFDictionary)
    }

    private func ensureRuntime() {
        guard app == nil && torOnlyApp == nil else { return }
        let dbPath = Self.databasePath() + ".tor-temp"
        // A leftover temp DB from a previous run can't be opened with a
        // fresh random key — clear it first.
        try? FileManager.default.removeItem(atPath: dbPath)
        try? FileManager.default.removeItem(atPath: dbPath + "-wal")
        try? FileManager.default.removeItem(atPath: dbPath + "-shm")
        let key = UUID().uuidString
        torOnlyApp = try? Ao3App(dbPath: dbPath, dbPassphrase: key)
        registerRecoveryHooks()
    }


    var hasDbPassword: Bool = UserDefaults.standard.bool(forKey: "userSetDbPassword") {
        didSet { Self.persistDbPasswordFlag(hasDbPassword) }
    }

    static func persistDbPasswordFlag(_ value: Bool) {
        UserDefaults.standard.set(value, forKey: "userSetDbPassword")
        UserDefaults.standard.synchronize()
    }

    static var promptForPassword: Bool {
        get { UserDefaults.standard.object(forKey: "promptForDbPassword") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "promptForDbPassword") }
    }

    // MARK: - Tor

    func connectTor() async {
        ensureRuntime()
        guard let runtime = app ?? torOnlyApp else {
            torStatus = .error("No runtime available")
            return
        }
        torStatus = .connecting
        do {
            try await runtime.connectTor()
            torStatus = .connected
            torHasConnectedOnce = true
            circuitHops = runtime.getCircuitHops()
        } catch let error as Ao3Error {
            switch error {
            case .Network(let msg):
                if msg.contains("timed out") {
                    torStatus = .error("Timed out — check your network")
                } else {
                    torStatus = .error(msg)
                }
            default:
                torStatus = .error(error.localizedDescription)
            }
        } catch {
            torStatus = .error(error.localizedDescription)
        }
    }

    func disconnectTor() async {
        guard let runtime = app ?? torOnlyApp else { return }
        try? await runtime.disconnectTor()
        torStatus = .disconnected
        circuitHops = []
        cloudflareReady = false
    }

    var circuitHops: [UCircuitHop] = []

    /// Return the local SOCKS5 proxy port, or 0 if Tor is not connected.
    func getSocksPort() -> UInt16 {
        guard let runtime = app ?? torOnlyApp else { return 0 }
        return runtime.getSocksPort()
    }

    /// Inject cookies (e.g. cf_clearance) into the reqwest cookie jar.
    func injectCookies(_ cookies: [String]) {
        guard let app else { return }
        app.injectCookies(cookies: cookies)
    }

    func checkTorStatus() {
        guard let app else { return }
        if app.isTorConnected() {
            torStatus = .connected
            circuitHops = app.getCircuitHops()
        }
    }

    func refreshCircuitHops() {
        guard let app else { return }
        circuitHops = app.getCircuitHops()
    }

    func newCircuit() async -> Bool {
        guard let app else { return false }
        do {
            try await app.newCircuit()
            circuitHops = app.getCircuitHops()
            return true
        } catch {
            return false
        }
    }

    func checkCircuitHealth() async -> Bool {
        guard let app else { return false }
        let healthy = (try? await app.checkCircuitHealth()) ?? false
        // The health check is usually the first stream on a fresh circuit, so
        // the Rust side has just captured the real path — pick it up now.
        circuitHops = app.getCircuitHops()
        return healthy
    }

    // MARK: - Network

    func cancelRequest() {
        app?.cancelRequest()
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
        (try? app?.getRouteTimeouts()) ?? []
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

    func fetchAuthorWorks(username: String, pseud: String? = nil, page: UInt32 = 1) async throws -> UPagedWorks {
        guard let app else { throw BridgeError.notInitialized }
        return try await app.fetchAuthorWorks(username: username, pseud: pseud, page: page)
    }

    /// One page of a user's public bookmarks — works and bookmarker-scoped
    /// bookmark rows are cached by the core.
    func fetchUserBookmarksPage(username: String, page: UInt32 = 1) async throws -> UPagedWorks {
        guard let app else { throw BridgeError.notInitialized }
        return try await app.fetchUserBookmarksPage(username: username, page: page)
    }

    /// One page of a user's collections — blurbs (tags included) are cached
    /// by the core like the public index.
    func fetchUserCollections(username: String, page: UInt32 = 1) async throws -> UCollectionsPage {
        guard let app else { throw BridgeError.notInitialized }
        return try await app.fetchUserCollections(username: username, page: page)
    }

    func fetchSeriesWorksPaged(seriesId: UInt64, page: UInt32 = 1) async throws -> UPagedWorks {
        guard let app else { throw BridgeError.notInitialized }
        return try await app.fetchSeriesWorksPaged(seriesId: seriesId, page: page)
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
    func searchWorksRawPaged(keys: [String], values: [String], page: UInt32 = 1) async throws -> UPagedWorks {
        guard let app else { throw BridgeError.notInitialized }
        return try await app.searchWorksRaw(keys: keys, values: values, page: page)
    }

    /// Paged variant of searchByTag.
    func searchByTagPaged(_ tag: String, page: UInt32 = 1) async throws -> UPagedWorks {
        guard let app else { throw BridgeError.notInitialized }
        return try await app.searchByTag(tag: tag, page: page)
    }

    /// One page of AO3's /bookmarks/search under the form's criteria —
    /// full bookmark hits (bookmarker, tags, note, rec, date) with the
    /// work blurb embedded. Results are cached like every listing (works +
    /// bookmark rows).
    func searchBookmarks(criteria: UBookmarkSearchCriteria, page: UInt32 = 1) async throws -> UPagedBookmarks {
        guard let app else { throw BridgeError.notInitialized }
        return try await app.searchBookmarks(criteria: criteria, page: page)
    }

    /// One page of the AO3 /collections index, optionally sorted/filtered
    /// with the index's collection_search criteria (nil = the plain index).
    func browseCollections(criteria: UCollectionSearchCriteria? = nil,
                           page: UInt32 = 1) async throws -> UCollectionsPage {
        guard let app else { throw BridgeError.notInitialized }
        return try await app.browseCollections(criteria: criteria, page: page)
    }

    /// One page of a collection's works. `name` is the collection's URL slug.
    func fetchCollectionWorks(name: String, page: UInt32 = 1) async throws -> UPagedWorks {
        guard let app else { throw BridgeError.notInitialized }
        return try await app.fetchCollectionWorks(name: name, page: page)
    }

    /// One page of a collection's bookmarked items (works only — series and
    /// external bookmarks are skipped).
    func fetchCollectionBookmarks(name: String, page: UInt32 = 1) async throws -> UPagedWorks {
        guard let app else { throw BridgeError.notInitialized }
        return try await app.fetchCollectionBookmarks(name: name, page: page)
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

    func fetchWorkFull(_ workId: UInt64) async throws -> UWorkSummary {
        guard let app else { throw BridgeError.notInitialized }
        return try await app.fetchWorkFull(workId: workId)
    }

    func fetchWork(_ workId: UInt64) async throws -> UWorkSummary {
        guard let app else { throw BridgeError.notInitialized }
        return try await app.fetchWork(workId: workId)
    }

    func fetchChapters(_ workId: UInt64) async throws -> [UChapter] {
        guard let app else { throw BridgeError.notInitialized }
        return try await app.fetchChapters(workId: workId)
    }

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

    static func databasePath() -> String {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let appDir = dir.appendingPathComponent("ArchiveOfYourOwn", isDirectory: true)
        try? FileManager.default.createDirectory(at: appDir, withIntermediateDirectories: true)
        return appDir.appendingPathComponent("library.db").path
    }


    // MARK: - Bookmark Sync

    func updateBookmarkNote(_ workId: UInt64, note: String) {
        try? app?.updateBookmarkNote(workId: workId, note: note)
    }

    /// Full AO3 bookmark object (notes, tags, collections, private/rec).
    func getBookmarkDetails(_ workId: UInt64) -> UBookmarkDetails? {
        (try? app?.getBookmarkDetails(workId: workId)) ?? nil
    }

    func updateBookmarkDetails(_ workId: UInt64, note: String, tagString: String,
                               collectionNames: String, private isPrivate: Bool, rec: Bool) {
        try? app?.updateBookmarkDetails(workId: workId, note: note, tagString: tagString,
                                        collectionNames: collectionNames, private: isPrivate, rec: rec)
    }

    func updateBookmarkSync(_ workId: UInt64, sync: Bool) {
        try? app?.updateBookmarkSync(workId: workId, sync: sync)
    }

    func isBookmarkSynced(_ workId: UInt64) -> Bool {
        (try? app?.isBookmarkSynced(workId: workId)) ?? false
    }

    func getBookmark(_ workId: UInt64) -> UBookmark? {
        try? app?.getBookmark(workId: workId)
    }

    func getAllBookmarksFull() -> [UBookmark] {
        (try? app?.getAllBookmarksFull()) ?? []
    }

    func pullBookmarks(username: String) async throws -> [UBookmark] {
        guard let app else { throw BridgeError.notInitialized }
        return try await app.pullBookmarks(username: username)
    }

    func pushBookmark(workId: UInt64) async throws -> Bool {
        guard let app else { throw BridgeError.notInitialized }
        return try await app.pushBookmark(workId: workId)
    }

    func deleteAo3Bookmark(workId: UInt64) async throws -> Bool {
        guard let app else { throw BridgeError.notInitialized }
        return try await app.deleteAo3Bookmark(workId: workId)
    }

    /// Toggle the AO3 subscription for a work; returns the new state
    /// (true = now subscribed). The Rust side prefers direct POSTs (cached
    /// token + stored record id) and mirrors the result into the local
    /// subscriptions table.
    func toggleWorkSubscription(workId: UInt64, username: String?) async throws -> Bool {
        guard let app else { throw BridgeError.notInitialized }
        return try await app.toggleWorkSubscription(workId: workId, username: username)
    }

    // MARK: - User profiles (subscribe / block / mute)

    /// The locally cached profile for a user — instant, DB-only.
    func getCachedUserProfile(username: String) -> UUserProfile? {
        guard let app else { return nil }
        return (try? app.getCachedUserProfile(username: username)) ?? nil
    }

    /// Fetch a user's profile from AO3 and cache it. Also mirrors live
    /// subscription state into the local subscriptions table.
    func fetchUserProfile(username: String) async throws -> UUserProfile {
        guard let app else { throw BridgeError.notInitialized }
        return try await app.fetchUserProfile(username: username)
    }

    /// Toggle the AO3 subscription for a user; returns the new state.
    func toggleUserSubscription(target: String, username: String?) async throws -> Bool {
        guard let app else { throw BridgeError.notInitialized }
        return try await app.toggleUserSubscription(target: target, username: username)
    }

    /// Toggle blocking a user on AO3; returns the new state.
    func toggleUserBlock(target: String, username: String) async throws -> Bool {
        guard let app else { throw BridgeError.notInitialized }
        return try await app.toggleUserBlock(target: target, username: username)
    }

    /// Toggle muting a user on AO3; returns the new state.
    func toggleUserMute(target: String, username: String) async throws -> Bool {
        guard let app else { throw BridgeError.notInitialized }
        return try await app.toggleUserMute(target: target, username: username)
    }

    func getSyncedBookmarkIds() -> [UInt64] {
        (try? app?.getSyncedBookmarkIds()) ?? []
    }

    func reauthenticate(password: String) async throws -> Bool {
        guard let app else { throw BridgeError.notInitialized }
        guard let creds = getCredentials(), let username = creds.first else {
            return false
        }
        let success = try await app.login(username: username, password: password)
        if success {
            _ = try? app.saveSessionCookies()
        }
        return success
    }

    // MARK: - AO3 Account

    func login(username: String, password: String) async throws -> Bool {
        guard let app else { throw BridgeError.notInitialized }
        return try await app.login(username: username, password: password)
    }

    func restoreSessionCookies() {
        _ = try? app?.restoreSessionCookies()
    }

    func saveSessionCookies() {
        _ = try? app?.saveSessionCookies()
    }

    func saveAccount(username: String) throws {
        guard let app else { throw BridgeError.notInitialized }
        try app.saveAccount(username: username)
    }

    func getCredentials() -> [String]? {
        guard let app else { return nil }
        return try? app.getCredentials()
    }

    func clearCredentials() {
        try? app?.clearCredentials()
    }

    // MARK: - Account Management

    func addAccount(username: String, password: String) async throws -> String {
        guard let app else { throw BridgeError.notInitialized }
        return try await app.addAccount(username: username, password: password)
    }

    func logoutAccount() async {
        try? await app?.logoutAccount()
    }

    func logoutSpecificAccount(accountId: String) async {
        try? await app?.logoutSpecificAccount(accountId: accountId)
    }

    func removeAccount(accountId: String) {
        try? app?.removeAccount(accountId: accountId)
    }

    func getAccounts() -> [(id: String, username: String, isActive: Bool)] {
        guard let app else { return [] }
        let raw = (try? app.getAccounts()) ?? []
        return raw.compactMap { arr in
            guard arr.count >= 3 else { return nil }
            return (id: arr[0], username: arr[1], isActive: arr[2] == "1")
        }
    }

    func switchAccount(accountId: String) -> (username: String, hasSession: Bool) {
        guard let app else { return ("", false) }
        let result = (try? app.switchAccount(accountId: accountId)) ?? []
        let username = result.first ?? ""
        let hasSession = result.count > 1 && result[1] == "1"
        return (username, hasSession)
    }

    func getActiveAccountUsername() -> String {
        guard let app else { return "" }
        return (try? app.getActiveAccountUsername()) ?? ""
    }

    // MARK: - Prefs, follows & work-list compute (Rust-owned state/logic)

    /// True once the encrypted DB is open — prefs and follows can load.
    var isDatabaseOpen: Bool { app != nil }

    func setPref(key: String, value: String) {
        try? app?.setPref(key: key, value: value)
    }

    func getPref(key: String) -> String? {
        (try? app?.getPref(key: key)) ?? nil
    }

    func getFollowed(kind: String) -> [String] {
        (try? app?.getFollowed(kind: kind)) ?? []
    }

    func addFollowed(kind: String, name: String) {
        try? app?.addFollowed(kind: kind, name: name)
    }

    func removeFollowed(kind: String, name: String) {
        try? app?.removeFollowed(kind: kind, name: name)
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

    func getLogs(limit: UInt32 = 500) -> [ULogEntry] {
        (try? app?.getLogs(limit: limit)) ?? []
    }

    func dumpLogs(limit: UInt32 = 1000) -> String {
        (try? app?.dumpLogs(limit: limit)) ?? ""
    }

    func clearLogs() {
        try? app?.clearLogs()
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

    func fetchSubscriptions(username: String) async throws -> [USubscription] {
        guard let app else { throw BridgeError.notInitialized }
        return try await app.fetchSubscriptions(username: username)
    }

    func persistSubscriptions(_ subscriptions: [USubscription]) throws {
        guard let app else { throw BridgeError.notInitialized }
        try app.persistSubscriptions(subscriptions: subscriptions)
    }

    func getPersistedSubscriptions() -> [USubscription] {
        (try? app?.getPersistedSubscriptions()) ?? []
    }

    func saveSubscriptionWorks(subType: String, subId: String, workIds: [UInt64]) {
        try? app?.saveSubscriptionWorks(subType: subType, subId: subId, workIds: workIds)
    }

    func getSubscriptionWorks(subType: String, subId: String) -> [UWorkSummary] {
        (try? app?.getSubscriptionWorks(subType: subType, subId: subId)) ?? []
    }

    func getWorksByAuthor(username: String) -> [UWorkSummary] {
        (try? app?.getWorksByAuthor(username: username)) ?? []
    }

    func startSubscriptionCheck(extraAuthors: [String] = [], onlyStale: Bool) throws -> UInt32 {
        guard let app else { throw BridgeError.notInitialized }
        return try app.startSubscriptionCheck(extraAuthors: extraAuthors, onlyStale: onlyStale)
    }

    /// True when any subscription's own last-checked stamp is missing or
    /// stale, or leftover queue items exist. Replaces gating on the global
    /// round-completion date, which overstated freshness for rows checked
    /// early in an interrupted round.
    func isSubscriptionCheckDue(extraAuthors: [String] = []) -> Bool {
        (try? app?.isSubscriptionCheckDue(extraAuthors: extraAuthors)) ?? false
    }

    /// Per-subscription last-completed-check stamps, keyed "subType:subId".
    func getSubscriptionLastChecked() -> [String: String] {
        (try? app?.getSubscriptionLastChecked()) ?? [:]
    }

    // MARK: - Library-scoped search (cached data only, no network)

    func searchLibraryWorks(_ term: String, limit: UInt32? = nil) -> [UWorkSummary] {
        (try? app?.searchLibraryWorks(term: term, limit: limit)) ?? []
    }

    func searchLibraryWorksFiltered(_ criteria: ULibrarySearchCriteria,
                                    limit: UInt32? = nil) -> [UWorkSummary] {
        (try? app?.searchLibraryWorksFiltered(criteria: criteria, limit: limit)) ?? []
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

    /// The cached works seen in a collection's /bookmarks listing — the
    /// library-mode view of its bookmarked items, no network.
    func getLibraryCollectionBookmarks(name: String) -> [UWorkSummary] {
        (try? app?.getLibraryCollectionBookmarks(name: name)) ?? []
    }

    func checkNextSubscription() async throws -> USubscriptionCheckResult? {
        guard let app else { throw BridgeError.notInitialized }
        return try await app.checkNextSubscription()
    }

    func resetSubscriptionCheck() {
        try? app?.resetSubscriptionCheck()
    }

    func getNewWorkIds() -> [UInt64] {
        (try? app?.getNewWorkIds()) ?? []
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
    func setWorksCrawledNow(subType: String, subId: String) {
        try? app?.setWorksCrawledNow(subType: subType, subId: subId)
    }

    /// Unix-seconds string of the last completed works crawl, or nil.
    func getWorksCrawledAt(subType: String, subId: String) -> String? {
        (try? app?.getWorksCrawledAt(subType: subType, subId: subId)) ?? nil
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

    func getLastSubscriptionCheck() -> String? {
        try? app?.getLastSubscriptionCheck()
    }

    // MARK: - Community Actions

    /// Works this device has successfully left kudos on (persisted in Rust).
    func getKudosGiven() -> [UInt64] {
        (try? app?.getKudosGiven()) ?? []
    }

    func leaveKudos(workId: UInt64) async throws -> Bool {
        guard let app else { throw BridgeError.notInitialized }
        return try await app.leaveKudos(workId: workId)
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
