import Foundation
import CryptoKit
#if canImport(UIKit)
import UIKit
#endif

// MARK: - iCloud library sync (transport)
//
// The shared copy in iCloud is the whole encrypted library as one file,
// keyed with a sync key that travels through iCloud Keychain, next to a
// small manifest naming the device that wrote it. The running app always
// works on its local database. The core (api/cloud_sync.rs) decides what
// the cloud copy means for this device; this service only moves files:
//
//   • this device's lineage is current in iCloud → keep the copy fresh on
//     an interval whenever the local library changed;
//   • another device wrote it → surface a choice (use the iCloud copy, or
//     replace it with this library), and carry out whichever was picked.
//
// Every replacement files the library being destroyed under the core's
// Backups/ first; the Backups section in Settings restores or removes
// those. Nothing here ever merges rows.

@Observable
@MainActor
final class CloudLibrarySync {
    enum Status: Equatable {
        case off
        /// No iCloud account, or the container isn't provisioned.
        case unavailable(String)
        /// Another device has published a copy but its key hasn't reached
        /// this device's keychain yet — iCloud Keychain usually catches up
        /// within a minute.
        case waitingForKey
        case idle
        case checking
        case uploading
        case downloading
        case replacing
        /// Sync is on but paused on a decision or a condition the user
        /// should know about.
        case attention(String)
        case error(String)

        var displayText: String {
            switch self {
            case .off: "Off"
            case .unavailable(let why): why
            case .waitingForKey: "Waiting for the sync key from iCloud Keychain…"
            case .idle: "Up to date"
            case .checking: "Checking iCloud…"
            case .uploading: "Updating the iCloud copy…"
            case .downloading: "Downloading the iCloud copy…"
            case .replacing: "Replacing the library…"
            case .attention(let msg): msg
            case .error(let msg): msg
            }
        }
    }

    /// Another device's library is in iCloud; the user decides.
    struct Conflict: Equatable {
        let deviceName: String
        let writtenAt: Date
        let generation: Int64
    }

    enum Resolution: Equatable {
        /// Back up this library, then replace it with the iCloud copy.
        case useCloudCopy
        /// Back up the iCloud copy, then replace it with this library.
        case overwriteCloudCopy
        /// Leave both as they are; ask again when iCloud changes.
        case notNow
    }

    struct Backup: Identifiable, Equatable {
        let id: String
        let createdAt: Date
        let reason: String
        let sourceDevice: String
        let sizeBytes: UInt64
    }

    private(set) var status: Status = .off
    private(set) var enabled = false
    private(set) var lastPushedAt: Date?
    private(set) var pendingConflict: Conflict?
    private(set) var backups: [Backup] = []
    private(set) var deviceId: String = ""
    /// A file swap or upload is in flight; the settings UI disables the
    /// destructive actions meanwhile.
    private(set) var busy = false
    /// Shown on other devices in the manifest.
    var deviceName: String = ""
    /// Platform hook to put the conflict in front of the user (the Mac
    /// app shows an NSAlert). When unset, the UI observes `pendingConflict`.
    @ObservationIgnored var presentConflict: ((Conflict) -> Void)?

    nonisolated static let folderName = "Shared"
    nonisolated static let libraryFileName = "library.aoyodb"
    nonisolated static let manifestFileName = "library.json"
    /// How often an owned cloud copy is refreshed while the library keeps
    /// changing. Foreground use also pushes on background/quit.
    nonisolated static let pushInterval: TimeInterval = 5 * 60

    private weak var appState: AppState?
    private var containerURL: URL?
    private var query: NSMetadataQuery?
    private var timer: Timer?
    private var observers: [NSObjectProtocol] = []
    private var cycleRunning = false
    private var cycleQueued = false
    private var forceNext = false
    /// A choice made while the iCloud copy was still downloading; carried
    /// out on the next cycle once the file is local.
    private var pendingResolution: (Resolution, Int64)?

    // MARK: Lifecycle

    /// Bind to the app state (idempotent) and start if the user has sync on.
    func attach(_ state: AppState) {
        appState = state
        if deviceName.isEmpty { deviceName = Self.defaultDeviceName() }
        let bridge = state.bridge
        guard bridge.isInitialized else { return }
        if let s = bridge.cloudSyncStatus() {
            deviceId = s.deviceId
            enabled = s.enabled
            lastPushedAt = s.lastPushAt.map { Date(timeIntervalSince1970: Double($0) / 1000) }
        }
        refreshBackups()
        if enabled { start() } else { status = .off }
    }

    /// Turn sync on or off for this device. Enabling on a device that finds
    /// no key in iCloud Keychain and no cloud copy mints the shared key.
    func setEnabled(_ on: Bool) {
        guard let bridge = appState?.bridge, bridge.isInitialized else { return }
        bridge.setCloudSyncEnabled(on)
        enabled = on
        if on {
            start(mintKeyIfFirst: true)
        } else {
            stop()
            pendingConflict = nil
            pendingResolution = nil
            status = .off
        }
    }

    /// Check iCloud now, and push if this device owns the copy.
    func syncNow() {
        guard enabled else { return }
        forceNext = true
        requestCycle()
    }

    /// Push before the process goes away (background, quit) when this
    /// device owns the cloud copy and the library changed. Synchronous on
    /// the caller's thread and bounded to local work: the manifest is only
    /// read if iCloud already delivered it.
    func flush() {
        guard enabled, !busy, let bridge = appState?.bridge, bridge.isInitialized, let app = bridge.coreApp,
              let dir = syncFolder(), let key = SyncKeychain.load() else { return }
        let manifest = Self.readManifest(in: dir, startDownload: false)
        guard case .available(let json) = manifest else { return }
        guard let verdict = try? app.cloudSyncEvaluate(manifestJson: json) else { return }
        switch verdict {
        case .noCloudCopy, .owned(needsPush: true): break
        default: return
        }
        #if canImport(UIKit)
        var task = UIBackgroundTaskIdentifier.invalid
        task = UIApplication.shared.beginBackgroundTask { UIApplication.shared.endBackgroundTask(task) }
        defer { UIApplication.shared.endBackgroundTask(task) }
        #endif
        if (try? Self.push(app: app, deviceName: deviceName, folder: dir, key: key)) != nil {
            lastPushedAt = Date()
        }
    }

    /// Delete the cloud copy and switch sync off here. Other devices keep
    /// their local libraries; the next one to push starts a new copy.
    func removeFromCloud() {
        stop()
        appState?.bridge.setCloudSyncEnabled(false)
        enabled = false
        pendingConflict = nil
        pendingResolution = nil
        status = .off
        guard let dir = syncFolder() else { return }
        let urls = [dir.appendingPathComponent(Self.libraryFileName), dir.appendingPathComponent(Self.manifestFileName)]
        DispatchQueue.global(qos: .utility).async {
            for url in urls {
                var coordError: NSError?
                NSFileCoordinator().coordinate(writingItemAt: url, options: .forDeleting, error: &coordError) { u in
                    try? FileManager.default.removeItem(at: u)
                }
            }
        }
    }

    /// The user answered the conflict prompt.
    func resolve(_ resolution: Resolution) {
        guard let conflict = pendingConflict else { return }
        pendingConflict = nil
        switch resolution {
        case .notNow:
            appState?.bridge.cloudSyncDismiss(generation: conflict.generation)
            status = .attention("Not syncing: iCloud holds \(conflict.deviceName)'s library.")
        case .useCloudCopy, .overwriteCloudCopy:
            pendingResolution = (resolution, conflict.generation)
            forceNext = true
            requestCycle()
        }
    }

    // MARK: Backups

    func refreshBackups() {
        guard let bridge = appState?.bridge, bridge.isInitialized else { return }
        backups = bridge.backupsList().map(Self.backup(from:))
    }

    /// Replace the library with a backup (the current library is filed as
    /// a new backup first). Reports failure through `status`.
    func restoreBackup(id: String) {
        guard !busy, let state = appState, state.bridge.isInitialized, let app = state.bridge.coreApp else { return }
        busy = true
        status = .replacing
        // From here until the maps are re-read, progress writes describe
        // the library being replaced and must not reach the new file.
        state.beginLibraryReplacement()
        Task { [weak self] in
            let result: Result<Void, Error> = await Task.detached(priority: .userInitiated) {
                do { _ = try app.backupRestore(id: id); return .success(()) } catch { return .failure(error) }
            }.value
            guard let self else { return }
            busy = false
            switch result {
            case .success:
                appState?.libraryWasReplaced()
                status = enabled ? .attention("Library restored from a backup. Sync it to iCloud, or use the iCloud copy, when prompted.") : .off
                if enabled { forceNext = true; requestCycle() }
            case .failure(let error):
                appState?.endLibraryReplacement()
                status = enabled ? .error(error.localizedDescription) : .off
            }
            refreshBackups()
        }
    }

    func deleteBackup(id: String) {
        deleteBackups(ids: [id])
    }

    /// Delete several backups in one pass. Keeps going past a failure so
    /// the rest are still removed; the first error is reported through
    /// `status`.
    func deleteBackups(ids: [String]) {
        guard let bridge = appState?.bridge, bridge.isInitialized else { return }
        var firstError: Error?
        for id in ids {
            do {
                try bridge.backupDelete(id: id)
            } catch {
                if firstError == nil { firstError = error }
            }
        }
        if let error = firstError {
            status = enabled ? .error(error.localizedDescription) : .off
        }
        refreshBackups()
    }

    // MARK: Engine

    private func start(mintKeyIfFirst: Bool = false) {
        guard timer == nil else { requestCycle(); return }
        guard FileManager.default.ubiquityIdentityToken != nil else {
            status = .unavailable("Sign in to iCloud in System Settings to sync.")
            return
        }
        status = .checking
        // Resolving the container can block; do it off the main thread once.
        Task { [weak self] in
            let url = await Task.detached(priority: .utility) {
                FileManager.default.url(forUbiquityContainerIdentifier: nil)
            }.value
            guard let self, self.enabled else { return }
            guard let url else {
                status = .unavailable("iCloud Drive isn't available for this app.")
                return
            }
            containerURL = url
            installQuery()
            timer = Timer.scheduledTimer(withTimeInterval: Self.pushInterval, repeats: true) { [weak self] _ in
                Task { @MainActor in self?.requestCycle() }
            }
            requestCycle(mintKeyIfFirst: mintKeyIfFirst)
        }
    }

    private func stop() {
        timer?.invalidate()
        timer = nil
        query?.stop()
        query = nil
        for o in observers { NotificationCenter.default.removeObserver(o) }
        observers = []
    }

    private func installQuery() {
        let q = NSMetadataQuery()
        q.searchScopes = [NSMetadataQueryUbiquitousDataScope]
        q.predicate = NSPredicate(format: "%K == %@ OR %K == %@",
                                  NSMetadataItemFSNameKey, Self.manifestFileName,
                                  NSMetadataItemFSNameKey, Self.libraryFileName)
        let names: [Notification.Name] = [.NSMetadataQueryDidFinishGathering, .NSMetadataQueryDidUpdate]
        for name in names {
            observers.append(NotificationCenter.default.addObserver(forName: name, object: q, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.requestCycle() }
            })
        }
        q.start()
        query = q
    }

    private func syncFolder() -> URL? {
        guard let containerURL else { return nil }
        return Self.syncFolder(in: containerURL)
    }

    nonisolated static func syncFolder(in containerURL: URL) -> URL {
        let dir = containerURL.appendingPathComponent(folderName, isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// One cycle: read the manifest, ask the core what it means, act.
    /// Cycles never overlap; a request during a running cycle queues
    /// exactly one more.
    private func requestCycle(mintKeyIfFirst: Bool = false) {
        // The core handle is captured here, on the main actor: a lock that
        // lands mid-cycle can't pull the library out from under the work,
        // and a nil handle can never be mistaken for a successful swap.
        guard enabled, let bridge = appState?.bridge, bridge.isInitialized, let app = bridge.coreApp,
              let dir = syncFolder() else { return }
        if cycleRunning || busy { cycleQueued = true; return }
        cycleRunning = true
        let deviceName = self.deviceName
        let force = forceNext
        forceNext = false
        let resolution = pendingResolution
        let lastPush = lastPushedAt
        let dismissedConflict = pendingConflict
        if status == .off || status == .idle { status = .checking }
        // This cycle may swap the library file underneath the UI (off the
        // main thread, before we hear about it): hold progress writes for
        // its whole duration so nothing stale lands in the adopted copy.
        let mayReplaceLibrary = resolution?.0 == .useCloudCopy
        if mayReplaceLibrary { appState?.beginLibraryReplacement() }

        Task { [weak self] in
            let result = await Task.detached(priority: .utility) {
                Self.runCycle(app: app, deviceName: deviceName, folder: dir,
                              mintKeyIfFirst: mintKeyIfFirst, force: force,
                              resolution: resolution, lastPush: lastPush)
            }.value
            guard let self else { return }
            cycleRunning = false
            if result.libraryReplaced {
                appState?.libraryWasReplaced()
                refreshBackups()
            } else if mayReplaceLibrary {
                appState?.endLibraryReplacement()
            }
            if result.backupsChanged { refreshBackups() }
            if let at = result.pushedAt { lastPushedAt = at }
            if result.resolutionDone { pendingResolution = nil }
            switch result.outcome {
            case .idle:
                status = .idle
            case .conflict(let conflict):
                status = .attention("iCloud holds \(conflict.deviceName)'s library.")
                if dismissedConflict != conflict {
                    pendingConflict = conflict
                    presentConflict?(conflict)
                }
            case .dismissedConflict(let name):
                status = .attention("Not syncing: iCloud holds \(name)'s library.")
            case .waitingForDownload:
                status = .downloading
            case .waitingForKey:
                status = .waitingForKey
            case .failed(let message):
                status = .error(message)
            }
            if cycleQueued {
                cycleQueued = false
                requestCycle()
            }
        }
    }

    // MARK: Off-main work

    private enum CycleOutcome {
        case idle
        case conflict(Conflict)
        case dismissedConflict(String)
        case waitingForDownload
        case waitingForKey
        case failed(String)
    }

    private struct CycleResult {
        var outcome: CycleOutcome
        var pushedAt: Date?
        var libraryReplaced = false
        var backupsChanged = false
        var resolutionDone = false
    }

    enum ManifestRead {
        /// `nil` json means iCloud holds no copy.
        case available(String?)
        case downloading
        case unreadable(String)
    }

    nonisolated private static func runCycle(app: Ao3App, deviceName: String, folder: URL,
                                             mintKeyIfFirst: Bool, force: Bool,
                                             resolution: (Resolution, Int64)?, lastPush: Date?) -> CycleResult {
        var result = CycleResult(outcome: .idle)

        let manifest = readManifest(in: folder, startDownload: true)
        let json: String?
        switch manifest {
        case .available(let j): json = j
        case .downloading:
            result.outcome = .waitingForDownload
            return result
        case .unreadable(let why):
            result.outcome = .failed(why)
            return result
        }

        // Key: use the one iCloud Keychain holds. Mint only when nothing is
        // in iCloud yet and the user just switched sync on here.
        var key = SyncKeychain.load()
        if key == nil {
            if json != nil || !mintKeyIfFirst {
                result.outcome = .waitingForKey
                return result
            }
            guard SyncKeychain.store(SyncKeychain.mint()) else {
                result.outcome = .failed("Couldn't store the sync key in iCloud Keychain.")
                return result
            }
            key = SyncKeychain.load()
        }
        guard let key else { return result }

        let verdict: UCloudVerdict
        do {
            verdict = try app.cloudSyncEvaluate(manifestJson: json)
        } catch {
            result.outcome = .failed(error.localizedDescription)
            return result
        }

        switch verdict {
        case .noCloudCopy:
            pushIfDue(&result, app: app, deviceName: deviceName, folder: folder, key: key, force: true, lastPush: lastPush)
            result.resolutionDone = true

        case .owned(let needsPush):
            if needsPush {
                pushIfDue(&result, app: app, deviceName: deviceName, folder: folder, key: key, force: force, lastPush: lastPush)
            }
            result.resolutionDone = true

        case .foreign(let name, let writtenAt, let generation, let dismissed):
            let conflict = Conflict(deviceName: name, writtenAt: Date(timeIntervalSince1970: Double(writtenAt) / 1000), generation: generation)
            if let (choice, forGeneration) = resolution {
                guard forGeneration == generation else {
                    // iCloud moved on while the user was deciding — ask again.
                    result.resolutionDone = true
                    result.outcome = .conflict(conflict)
                    return result
                }
                carryOut(choice, conflict: conflict, into: &result, app: app, deviceName: deviceName, folder: folder, key: key)
            } else if dismissed {
                result.outcome = .dismissedConflict(name)
            } else {
                result.outcome = .conflict(conflict)
            }

        case .needsAppUpdate(let schemaVersion):
            result.outcome = .failed("The iCloud copy was written by a newer app (library format \(schemaVersion)). Update this app to sync.")

        case .unreadable(let message):
            result.outcome = .failed("The iCloud manifest couldn't be read: \(message)")
        }
        return result
    }

    nonisolated private static func pushIfDue(_ result: inout CycleResult, app: Ao3App, deviceName: String,
                                              folder: URL, key: String, force: Bool, lastPush: Date?) {
        if !force, let lastPush, Date().timeIntervalSince(lastPush) < pushInterval { return }
        do {
            _ = try push(app: app, deviceName: deviceName, folder: folder, key: key)
            result.pushedAt = Date()
        } catch {
            result.outcome = .failed("Couldn't update the iCloud copy: \(error.localizedDescription)")
        }
    }

    /// Carry out the user's choice for a foreign copy. Both choices need
    /// the cloud library file itself: adoption swaps it in, overwriting
    /// files it away as a backup first.
    nonisolated private static func carryOut(_ choice: Resolution, conflict: Conflict, into result: inout CycleResult,
                                             app: Ao3App, deviceName: String, folder: URL, key: String) {
        let staged: URL
        switch stageCloudLibrary(in: folder) {
        case .success(let url): staged = url
        case .failure(.downloading):
            result.outcome = .waitingForDownload
            return
        case .failure(.failed(let message)):
            result.outcome = .failed(message)
            result.resolutionDone = true
            return
        }
        defer { try? FileManager.default.removeItem(at: staged) }
        do {
            switch choice {
            case .useCloudCopy:
                _ = try app.cloudSyncAdopt(stagedPath: staged.path, cloudKey: key, expectedGeneration: conflict.generation)
                result.libraryReplaced = true
                result.backupsChanged = true
                result.pushedAt = Date()
                result.resolutionDone = true
            case .overwriteCloudCopy:
                _ = try app.cloudSyncStashForeignCopy(stagedPath: staged.path, cloudKey: key, expectedGeneration: conflict.generation)
                result.backupsChanged = true
                _ = try push(app: app, deviceName: deviceName, folder: folder, key: key)
                result.pushedAt = Date()
                result.resolutionDone = true
            case .notNow:
                result.resolutionDone = true
            }
        } catch {
            // "Still updating" means the file iCloud delivered is behind
            // the manifest — leave the choice pending for the next cycle.
            let message = error.localizedDescription
            if message.contains("still updating") {
                result.outcome = .waitingForDownload
            } else {
                result.outcome = .failed(message)
                result.resolutionDone = true
            }
        }
    }

    enum StageFailure: Error { case downloading, failed(String) }

    /// Where the cloud library file stands on this device. Asks iCloud to
    /// download it when it isn't local yet.
    enum CloudFileState { case local, downloading, missing }

    nonisolated static func cloudLibraryFileState(in folder: URL) -> CloudFileState {
        let fm = FileManager.default
        let url = folder.appendingPathComponent(libraryFileName)
        let placeholder = folder.appendingPathComponent(".\(libraryFileName).icloud")
        if !fm.fileExists(atPath: url.path) {
            if fm.fileExists(atPath: placeholder.path) {
                try? fm.startDownloadingUbiquitousItem(at: url)
                return .downloading
            }
            return .missing
        }
        if let values = try? url.resourceValues(forKeys: [.ubiquitousItemDownloadingStatusKey]),
           let s = values.ubiquitousItemDownloadingStatus, s != .current {
            try? fm.startDownloadingUbiquitousItem(at: url)
            return .downloading
        }
        return .local
    }

    /// Copy the cloud library file into the core's directory, coordinated,
    /// once iCloud has it fully local.
    nonisolated static func stageCloudLibrary(in folder: URL) -> Result<URL, StageFailure> {
        let fm = FileManager.default
        let url = folder.appendingPathComponent(libraryFileName)
        switch cloudLibraryFileState(in: folder) {
        case .downloading: return .failure(.downloading)
        case .missing: return .failure(.failed("The iCloud copy's library file is missing."))
        case .local: break
        }
        let staged = RustBridge.stateDirectory().appendingPathComponent("cloud-incoming.aoyodb")
        try? fm.removeItem(at: staged)
        var coordError: NSError?
        var copyError: Error?
        NSFileCoordinator().coordinate(readingItemAt: url, options: [], error: &coordError) { u in
            do { try fm.copyItem(at: u, to: staged) } catch { copyError = error }
        }
        if let coordError { return .failure(.failed(coordError.localizedDescription)) }
        if let copyError { return .failure(.failed(copyError.localizedDescription)) }
        return .success(staged)
    }

    /// The manifest as iCloud currently has it. With `startDownload`, a
    /// not-yet-local manifest is requested and reported as downloading;
    /// without it (the quit-time flush) it simply isn't available.
    nonisolated static func readManifest(in folder: URL, startDownload: Bool) -> ManifestRead {
        let fm = FileManager.default
        let url = folder.appendingPathComponent(manifestFileName)
        let placeholder = folder.appendingPathComponent(".\(manifestFileName).icloud")
        if !fm.fileExists(atPath: url.path) {
            if fm.fileExists(atPath: placeholder.path) {
                if startDownload { try? fm.startDownloadingUbiquitousItem(at: url) }
                return startDownload ? .downloading : .unreadable("manifest not downloaded")
            }
            return .available(nil)
        }
        if let values = try? url.resourceValues(forKeys: [.ubiquitousItemDownloadingStatusKey]),
           let s = values.ubiquitousItemDownloadingStatus, s != .current {
            if startDownload { try? fm.startDownloadingUbiquitousItem(at: url) }
            return startDownload ? .downloading : .unreadable("manifest not downloaded")
        }
        var data: Data?
        var coordError: NSError?
        NSFileCoordinator().coordinate(readingItemAt: url, options: [], error: &coordError) { u in
            data = try? Data(contentsOf: u)
        }
        guard let data, let json = String(data: data, encoding: .utf8) else {
            return .unreadable("Couldn't read the iCloud manifest.")
        }
        return .available(json)
    }

    /// Export the library, place the copy in iCloud, then the manifest —
    /// in that order, so a reader never pairs a new manifest with an old
    /// file for long — and only then tell the core the push happened.
    @discardableResult
    nonisolated private static func push(app: Ao3App, deviceName: String, folder: URL, key: String) throws -> Int64 {
        let staging = RustBridge.stateDirectory().appendingPathComponent("cloud-export.aoyodb")
        defer { try? FileManager.default.removeItem(at: staging) }
        let export = try app.cloudSyncExport(stagingPath: staging.path, cloudKey: key, deviceName: deviceName)
        try coordinatedReplace(at: folder.appendingPathComponent(libraryFileName), with: staging)
        let manifestTmp = RustBridge.stateDirectory().appendingPathComponent("cloud-manifest.json")
        try Data(export.manifestJson.utf8).write(to: manifestTmp, options: .atomic)
        defer { try? FileManager.default.removeItem(at: manifestTmp) }
        try coordinatedReplace(at: folder.appendingPathComponent(manifestFileName), with: manifestTmp)
        try app.cloudSyncMarkPushed(generation: export.generation)
        return export.generation
    }

    nonisolated private static func coordinatedReplace(at url: URL, with source: URL) throws {
        var coordError: NSError?
        var writeError: Error?
        NSFileCoordinator().coordinate(writingItemAt: url, options: .forReplacing, error: &coordError) { u in
            do {
                let fm = FileManager.default
                if fm.fileExists(atPath: u.path) {
                    _ = try fm.replaceItemAt(u, withItemAt: source)
                } else {
                    try fm.copyItem(at: source, to: u)
                }
            } catch { writeError = error }
        }
        if let coordError { throw coordError }
        if let writeError { throw writeError }
    }

    nonisolated private static func backup(from info: UBackupInfo) -> Backup {
        Backup(id: info.id,
               createdAt: Date(timeIntervalSince1970: Double(info.createdAt) / 1000),
               reason: info.reason,
               sourceDevice: info.sourceDevice,
               sizeBytes: info.sizeBytes)
    }

    static func defaultDeviceName() -> String {
        #if canImport(UIKit)
        return UIDevice.current.name
        #else
        return Host.current().localizedName ?? "Mac"
        #endif
    }
}

// MARK: - Shared key (iCloud Keychain)

/// The one secret every device needs: a 256-bit key stored as a
/// synchronizable keychain item, so iCloud Keychain carries it between the
/// user's devices and nothing else ever does. The cloud copy is a SQLCipher
/// file keyed with this (as hex); the local library keeps its own
/// per-device key, which never leaves the device.
///
/// The item lives in a keychain access group both apps declare in their
/// entitlements: iCloud Keychain only delivers an item to the same group,
/// and the iOS and Mac apps have different bundle ids, so without a shared
/// group the Mac's key would never reach the iPhone.
enum SyncKeychain {
    private static let service = "com.archiveofyourown.reader.icloud-sync"
    private static let account = "library-sync-key"
    private static let accessGroup = "com.archiveofyourown.reader.shared"

    /// `<team id>.com.archiveofyourown.reader.shared`. The team prefix is
    /// stamped into Info.plist at build time (`AppIdentifierPrefix`), so
    /// it never has to be written down here.
    private static var groupName: String? {
        guard let prefix = Bundle.main.object(forInfoDictionaryKey: "AppIdentifierPrefix") as? String,
              !prefix.isEmpty, prefix.hasSuffix(".") else { return nil }
        return prefix + accessGroup
    }

    private static var baseQuery: [String: Any] {
        var q: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecAttrSynchronizable as String: kCFBooleanTrue!,
        ]
        if let groupName { q[kSecAttrAccessGroup as String] = groupName }
        #if os(macOS)
        q[kSecUseDataProtectionKeychain as String] = true
        #endif
        return q
    }

    /// The key as the SQLCipher passphrase string used for the cloud copy.
    /// A key minted before the shared access group existed (this device's
    /// own group) is copied into the shared group on first sight, so the
    /// device that already published keeps its key and the others get it.
    /// The old item is left alone: a delete query without an access group
    /// matches every group, the shared copy included.
    static func load() -> String? {
        if let data = loadData(baseQuery) {
            return hex(data)
        }
        guard groupName != nil, let legacy = loadData(legacyQuery) else { return nil }
        store(legacy)
        return hex(loadData(baseQuery) ?? legacy)
    }

    private static var legacyQuery: [String: Any] {
        var q = baseQuery
        q.removeValue(forKey: kSecAttrAccessGroup as String)
        return q
    }

    private static func loadData(_ query: [String: Any]) -> Data? {
        var q = query
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: AnyObject?
        let status = SecItemCopyMatching(q as CFDictionary, &out)
        guard status == errSecSuccess, let data = out as? Data, data.count == 32 else { return nil }
        return data
    }

    private static func hex(_ data: Data) -> String {
        data.map { String(format: "%02x", $0) }.joined()
    }

    static func mint() -> Data {
        SymmetricKey(size: .bits256).withUnsafeBytes { Data($0) }
    }

    /// Store `key` unless another device's key arrived in the meantime —
    /// the existing item wins, so two devices enabling sync at once can't
    /// end up with different keys.
    @discardableResult
    static func store(_ key: Data) -> Bool {
        var q = baseQuery
        q[kSecValueData as String] = key
        q[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        let status = SecItemAdd(q as CFDictionary, nil)
        return status == errSecSuccess || status == errSecDuplicateItem
    }

    static func delete() {
        SecItemDelete(baseQuery as CFDictionary)
    }
}
