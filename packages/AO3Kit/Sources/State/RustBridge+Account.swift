import Foundation

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
}
