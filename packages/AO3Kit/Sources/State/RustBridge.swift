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
            app = try Ao3App(dbPath: dbPath, dbPassphrase: key)
            torOnlyApp = nil
            isInitialized = true
            connectionError = nil
            return true
        } catch {
            connectionError = error.localizedDescription
            return false
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
        let key = UUID().uuidString
        torOnlyApp = try? Ao3App(dbPath: dbPath, dbPassphrase: key)
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
        return (try? await app.checkCircuitHealth()) ?? false
    }

    // MARK: - Network

    func cancelRequest() {
        app?.cancelRequest()
    }

    func getFetchProgress(operation: String) -> UFetchProgress? {
        app?.getFetchProgress(operation: operation)
    }

    func setRequestTimeout(_ seconds: UInt64) {
        app?.setRequestTimeout(seconds: seconds)
    }

    func getRequestTimeout() -> UInt64 {
        app?.getRequestTimeout() ?? 30
    }

    func fetchSearchForm() async throws -> [UFormField] {
        guard let app else { throw BridgeError.notInitialized }
        return try await app.fetchSearchForm()
    }

    func fetchAuthorWorks(username: String, page: UInt32 = 1) async throws -> UPagedWorks {
        guard let app else { throw BridgeError.notInitialized }
        return try await app.fetchAuthorWorks(username: username, page: page)
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

    func searchWorksRaw(keys: [String], values: [String], page: UInt32 = 1) async throws -> [UWorkSummary] {
        guard let app else { throw BridgeError.notInitialized }
        return try await app.searchWorksRaw(keys: keys, values: values, page: page)
    }

    func searchByTag(_ tag: String, page: UInt32 = 1) async throws -> [UWorkSummary] {
        guard let app else { throw BridgeError.notInitialized }
        return try await app.searchByTag(tag: tag, page: page)
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
        try? app?.saveSearch(name: name, paramsJson: paramsJson)
    }

    func getSavedSearches() -> [USavedSearch] {
        (try? app?.getSavedSearches()) ?? []
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

    func saveProgress(workId: UInt64, chapter: UInt32, position: Double) {
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

    func getSyncedBookmarkIds() -> [UInt64] {
        (try? app?.getSyncedBookmarkIds()) ?? []
    }

    func ensureLoggedIn() async -> Bool {
        guard let app else { return false }
        return (try? await app.ensureLoggedIn()) ?? false
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

    func isLoggedIn() async throws -> Bool {
        guard let app else { return false }
        return try await app.isLoggedIn()
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

    func startSubscriptionCheck() throws -> UInt32 {
        guard let app else { throw BridgeError.notInitialized }
        return try app.startSubscriptionCheck()
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
