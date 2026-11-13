import Foundation

struct AO3Account: Identifiable, Equatable {
    let id: String
    let username: String
    let isActive: Bool
    let isLoggedIn: Bool
}

extension RustBridge {
    // MARK: - First-launch bootstrap (no library yet)

    /// Backups still on disk beside where the library would be — left by
    /// a library that vanished, or by an earlier install.
    nonisolated static func bootstrapBackups() -> [UBackupInfo] {
        libraryBootstrapBackups(dbPath: databasePath())
    }

    /// The auto key already in the Keychain, if any — read without
    /// minting, so a probe for an old backup's key can't replace it.
    static func existingAutoKey() -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: autoKeyAccount,
            kSecReturnData as String: true,
        ]
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// The passphrase a library started from iCloud or a backup will be
    /// keyed with: the user's password, or a freshly minted auto key that
    /// is stored now so `open()` finds it afterwards.
    static func localKeyForNewLibrary(password: String?) -> String {
        password ?? generateAndStoreAutoKey()
    }

    /// Open a library that a bootstrap just placed at the database path,
    /// recording how it is protected exactly as the create paths do.
    func openBootstrapped(password: String?) -> Bool {
        guard open(userPassword: password) else { return false }
        hasDbPassword = password != nil
        Self.persistDbPasswordFlag(hasDbPassword)
        if password != nil { Self.deleteAutoKey() }
        return true
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

    // MARK: - User profiles (subscribe / block / mute)

    // MARK: - Users by row id (design/users-model-plan.md)

    /// A user from the library, by row id. DB-only.
    func getUser(_ id: UInt64) -> UUser? {
        app?.getUser(userId: id)
    }

    /// Fetch a user's profile from their source and cache it.
    func fetchUser(_ id: UInt64) async throws -> UUser {
        guard let app else { throw BridgeError.notInitialized }
        return try await app.fetchUser(userId: id)
    }

    /// Works in the library by this user, newest update first.
    func getWorksByUser(_ id: UInt64) -> [UWorkSummary] {
        guard let app else { return [] }
        return (try? app.getWorksByUser(userId: id)) ?? []
    }

    /// One page of a user's works at their source.
    func fetchUserWorks(_ id: UInt64, page: UInt32, opID: UInt64? = nil) async throws -> UPagedWorks {
        guard let app else { throw BridgeError.notInitialized }
        return try await app.fetchUserWorks(userId: id, page: page, opId: opID)
    }

    /// The users row for an AO3 username the library already knows; nil
    /// when never seen. Never creates a row — safe in a render pass.
    func lookupAO3UserID(_ username: String) -> UInt64? {
        app?.lookupAo3UserId(username: username)
    }

    /// Which source recognises a profile link, and the user key it names.
    func resolveUserLink(_ link: String) -> UResolvedLink? {
        app?.resolveUserLink(link: link)
    }

    /// Users at a source whose names match, as that source ranks them.
    /// Empty for a source without user search.
    func searchUsers(source: String, query: String) async throws -> [UUserHit] {
        guard let app else { throw BridgeError.notInitialized }
        return try await app.searchUsers(source: source, query: query)
    }

    /// The users row for a source key (created when never seen).
    func ensureUser(source: String, sourceID: String, url: String, username: String) -> UInt64? {
        guard let app else { return nil }
        return try? app.ensureUser(source: source, sourceId: sourceID, url: url, username: username)
    }

    /// The users row for an AO3 username (created when never seen) — how
    /// AO3-keyed surfaces (follows, subscriptions, pasted links, comment
    /// bylines) reach the id-keyed author screens.
    func userID(forAO3Username username: String) -> UInt64? {
        guard let app else { return nil }
        return (try? app.userIdForAo3Username(username: username)) ?? nil
    }

    /// Every source the app knows, in display order (fetched once).
    func listSources() -> [SourceCapabilities] {
        if let cached = Self.allSources { return cached }
        let all = app?.listSources() ?? []
        if !all.isEmpty { Self.allSources = all; for s in all { Self.capabilitiesByID[s.id] = s } }
        return all
    }
    private static var allSources: [SourceCapabilities]?

    /// What a source offers, fetched once per source id and kept; nil for
    /// an unknown id.
    func sourceCapabilities(_ sourceID: String) -> SourceCapabilities? {
        if let cached = Self.capabilitiesByID[sourceID] { return cached }
        guard let caps = app?.sourceCapabilities(sourceId: sourceID) else { return nil }
        Self.capabilitiesByID[sourceID] = caps
        return caps
    }
    private static var capabilitiesByID: [String: SourceCapabilities] = [:]

    // MARK: - Controls (design/source-controls-plan.md)

    /// What the user can do with a work right now — shape, gates and
    /// words from its source. Cache-only in Rust; call on render.
    func workControls(_ workID: UInt64) -> WorkControls? {
        app?.workControls(workId: workID)
    }

    func userControls(_ userID: UInt64) -> UserControls? {
        app?.userControls(userId: userID)
    }

    func tagControls(source: String, tag: String) -> TagControls? {
        app?.tagControls(sourceId: source, tag: tag)
    }

    /// Whether a stored sign-in at the source still carries its login.
    func isSignedIn(source: String) -> Bool {
        app?.isSignedIn(sourceId: source) ?? false
    }

    /// The locally cached profile for a user — instant, DB-only.
    func getCachedUserProfile(username: String) -> UUserProfile? {
        guard let app else { return nil }
        return (try? app.getCachedUserProfile(username: username)) ?? nil
    }

    /// Fetch a user's profile from AO3 and cache it. Also mirrors live
    /// subscription state into the signed-in account's subscriptions
    /// (never follows).
    func fetchUserProfile(username: String) async throws -> UUserProfile {
        guard let app else { throw BridgeError.notInitialized }
        return try await app.fetchUserProfile(username: username)
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

    /// `isLoggedIn` is per account: whether its stored session holds an
    /// AO3 login, independent of which account is active.
    func getAccounts() -> [AO3Account] {
        guard let app else { return [] }
        let raw = (try? app.getAccounts()) ?? []
        return raw.compactMap { arr in
            guard arr.count >= 4 else { return nil }
            return AO3Account(id: arr[0], username: arr[1], isActive: arr[2] == "1", isLoggedIn: arr[3] == "1")
        }
    }

    func switchAccount(accountId: String) -> (username: String, hasSession: Bool) {
        guard let app else { return ("", false) }
        let result = (try? app.switchAccount(accountId: accountId)) ?? []
        let username = result.first ?? ""
        let hasSession = result.count > 1 && result[1] == "1"
        return (username, hasSession)
    }

    /// Every source that has sign-in, with its accounts and how one is
    /// added (by password, or on the site's own page).
    func accountGroups() -> [UAccountGroup] {
        app?.accountGroups() ?? []
    }

    /// Sign in on the source's own page; the account that results is
    /// saved and made that source's active one.
    func signInAtSite(source: String) async throws -> UAccount {
        guard let app else { throw BridgeError.notInitialized }
        return try await app.signInAtSite(source: source)
    }

    func getActiveAccountUsername() -> String {
        guard let app else { return "" }
        return (try? app.getActiveAccountUsername()) ?? ""
    }
}
