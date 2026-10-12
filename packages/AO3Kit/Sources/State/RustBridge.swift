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

/// The Swift face of the core. Main-actor isolated: every property here
/// is observed by views, and `app` is swapped on lock/unlock, so nothing
/// may read or write it off the main thread. Work that must leave the
/// main thread (file copies, whole-library exports) takes an `Ao3App`
/// snapshot via `coreApp` and calls the core directly — the handle is
/// Sendable and keeps the library open for as long as the work holds it.
@Observable
@MainActor
final class RustBridge {
    var app: Ao3App?
    var isInitialized = false

    /// The open core, for detached work that outlives a main-thread hop.
    /// nil while locked or before the library exists. Callers snapshot it
    /// on the main actor and never store it past the work at hand.
    var coreApp: Ao3App? { app }
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

    nonisolated static var dbFileExists: Bool {
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
    /// Why the last `open`/`verifyPassword` failed. Only `.wrongPassword`
    /// is a bad key; everything else (schema newer than this build, damaged
    /// file, missing keychain item) carries the real message and must not
    /// be counted as a password attempt.
    enum DbOpenFailure: Equatable {
        case wrongPassword
        case other(String)

        var message: String {
            switch self {
            case .wrongPassword: return "Wrong password."
            case .other(let m): return m
            }
        }
    }
    var lastOpenFailure: DbOpenFailure?

    /// The failure classification for an error thrown by `Ao3App`.
    private static func classifyOpenError(_ error: Error) -> DbOpenFailure {
        if case Ao3Error.WrongPassword = error { return .wrongPassword }
        return .other(Self.describeOpenError(error))
    }

    /// The message inside the Rust error, without the Swift enum wrapper.
    private static func describeOpenError(_ error: Error) -> String {
        if let e = error as? Ao3Error {
            switch e {
            case .Storage(let m), .Network(let m), .Parse(let m), .NotFound(let m), .Http(_, let m):
                return m
            default:
                return "\(e)"
            }
        }
        return error.localizedDescription
    }

    func open(userPassword: String? = nil) -> Bool {
        lastOpenFailure = nil
        guard let key = userPassword ?? Self.autoKey() else {
            connectionError = "Could not read the database key from the Keychain. Grant keychain access and relaunch."
            lastOpenFailure = .other(connectionError!)
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
            let failure = Self.classifyOpenError(error)
            lastOpenFailure = failure
            connectionError = failure.message
            NSLog("[db] open failed: %@", failure.message)
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
        lastOpenFailure = nil
        do {
            let testApp = try Ao3App(dbPath: dbPath, dbPassphrase: password)
            // If it opened successfully, the password is correct.
            // We don't keep this instance — just testing.
            _ = testApp
            return true
        } catch {
            lastOpenFailure = Self.classifyOpenError(error)
            return false
        }
    }

    // MARK: - Auto Key (Keychain)

    static let autoKeyAccount = "ao3_auto_db_key"

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

    static func generateAndStoreAutoKey() -> String {
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

    static func deleteAutoKey() {
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
}
