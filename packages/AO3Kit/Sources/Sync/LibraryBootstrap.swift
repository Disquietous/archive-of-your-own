import Foundation

// MARK: - First launch: start from iCloud, a backup, or fresh
//
// The launch gate reaches this when no library file exists. Before an
// empty database is created, look for one the user already has: the copy
// another device (or this one, before a reinstall) published to iCloud,
// and any backups still under the app's Backups/ folder. The user picks;
// nothing is created until they do. The core does the actual work
// (api/cloud_sync.rs bootstrap functions); this model only probes iCloud,
// stages files, and sequences the choice.

@Observable
@MainActor
final class LibraryBootstrap {
    enum Source: Equatable {
        case new
        case cloud
        case backup(id: String)
    }

    enum Step: Equatable {
        /// Looking for an existing library; the text says where.
        case probing(String)
        /// Something was found — the user chooses.
        case choose
        /// The source is picked; choose how to protect the library.
        case protect(Source)
        /// A backup's own password is needed (no matching auto key).
        case backupPassword(id: String)
        /// A file operation is in flight; the text says which.
        case working(String)
    }

    struct CloudCandidate: Equatable {
        enum Availability: Equatable {
            case ready
            /// iCloud hasn't finished delivering the library file.
            case downloading
            /// The sync key hasn't reached this device's iCloud Keychain.
            case waitingForKey
        }
        let deviceName: String
        let writtenAt: Date
        let generation: Int64
        let sizeBytes: UInt64
        var availability: Availability

        var note: String? {
            switch availability {
            case .ready: nil
            case .downloading: "Downloading from iCloud…"
            case .waitingForKey: "Waiting for the sync key from iCloud Keychain…"
            }
        }
    }

    private(set) var step: Step = .probing("Looking for an existing library…")
    private(set) var cloud: CloudCandidate?
    private(set) var backups: [CloudLibrarySync.Backup] = []
    /// Set when a library was just protected with a password; the gate
    /// shows it once, as the create path does.
    private(set) var recoveryKey: String?
    var error: String?

    var hasCandidates: Bool { cloud != nil || !backups.isEmpty }

    private let bridge: RustBridge
    private var cloudFolder: URL?
    private var probeTask: Task<Void, Never>?
    /// Stamps each probe so a cancelled one finishing late can't clear the
    /// handle of the probe that replaced it.
    private var probeGeneration = 0

    /// How long the initial probe waits for iCloud to say whether a copy
    /// exists before offering only what's already known.
    private static let probeDeadline: TimeInterval = 12
    /// While the chooser is up, iCloud is re-checked at this interval so a
    /// downloading file or a late sync key turns the option on by itself.
    private static let pollInterval: TimeInterval = 2
    private static let pollFor: TimeInterval = 120

    init(bridge: RustBridge) {
        self.bridge = bridge
    }

    // MARK: Probe

    func start() {
        guard probeTask == nil else { return }
        backups = RustBridge.bootstrapBackups().map { info in
            CloudLibrarySync.Backup(id: info.id,
                                    createdAt: Date(timeIntervalSince1970: Double(info.createdAt) / 1000),
                                    reason: info.reason, sourceDevice: info.sourceDevice, sizeBytes: info.sizeBytes)
        }
        launchProbe()
    }

    private func launchProbe() {
        probeGeneration += 1
        let generation = probeGeneration
        probeTask = Task { [weak self] in
            await self?.probe()
            guard let self, self.probeGeneration == generation else { return }
            self.probeTask = nil
        }
    }

    func cancelProbe() {
        probeTask?.cancel()
        probeTask = nil
    }

    private func probe() async {
        guard FileManager.default.ubiquityIdentityToken != nil else {
            settleProbe()
            return
        }
        step = .probing("Checking iCloud for your library…")
        let container = await Task.detached(priority: .userInitiated) {
            FileManager.default.url(forUbiquityContainerIdentifier: nil)
        }.value
        guard !Task.isCancelled else { return }
        guard let container else {
            settleProbe()
            return
        }
        let folder = CloudLibrarySync.syncFolder(in: container)
        cloudFolder = folder

        let started = Date()
        var settled = false
        while !Task.isCancelled, Date().timeIntervalSince(started) < Self.pollFor {
            let read = await Task.detached(priority: .userInitiated) {
                Self.readCandidate(in: folder)
            }.value
            guard !Task.isCancelled else { return }
            switch read {
            case .none:
                cloud = nil
                if !settled { settleProbe(); settled = true }
                if case .choose = step, backups.isEmpty { step = .protect(.new) }
                return
            case .pending:
                // Manifest still downloading: keep the probe up until the
                // deadline, then offer what's known and keep polling.
                if !settled, Date().timeIntervalSince(started) >= Self.probeDeadline {
                    settleProbe(); settled = true
                }
            case .found(let candidate):
                cloud = candidate
                if !settled { settleProbe(); settled = true }
                if candidate.availability == .ready { return }
            }
            // Keep polling only while the user can still act on the result.
            switch step {
            case .probing, .choose: break
            default: return
            }
            try? await Task.sleep(nanoseconds: UInt64(Self.pollInterval * 1_000_000_000))
        }
    }

    /// Move from the probe to the first decision the user can make with
    /// what has been found so far.
    private func settleProbe() {
        guard case .probing = step else { return }
        step = hasCandidates ? .choose : .protect(.new)
    }

    private enum CandidateRead {
        case none
        case pending
        case found(CloudCandidate)
    }

    nonisolated private static func readCandidate(in folder: URL) -> CandidateRead {
        switch CloudLibrarySync.readManifest(in: folder, startDownload: true) {
        case .available(nil), .unreadable:
            return .none
        case .downloading:
            return .pending
        case .available(let json?):
            guard let manifest = try? cloudManifestParse(manifestJson: json) else { return .none }
            let availability: CloudCandidate.Availability
            if SyncKeychain.load() == nil {
                availability = .waitingForKey
            } else if CloudLibrarySync.cloudLibraryFileState(in: folder) != .local {
                availability = .downloading
            } else {
                availability = .ready
            }
            return .found(CloudCandidate(deviceName: manifest.deviceName,
                                         writtenAt: Date(timeIntervalSince1970: Double(manifest.writtenAt) / 1000),
                                         generation: manifest.generation,
                                         sizeBytes: manifest.dbSize,
                                         availability: availability))
        }
    }

    // MARK: Choices

    /// The user picked where the library comes from.
    func choose(_ source: Source) {
        error = nil
        switch source {
        case .new, .cloud:
            cancelProbe()
            step = .protect(source)
        case .backup(let id):
            cancelProbe()
            // A backup keeps the key it was made under. The auto key in the
            // Keychain usually still matches; otherwise the user knows the
            // password.
            guard let key = RustBridge.existingAutoKey() else {
                step = .backupPassword(id: id)
                return
            }
            Task { await restoreBackup(id: id, key: key, password: nil) }
        }
    }

    /// Back out of a password prompt or the protect step to the chooser.
    func backToChoices() {
        error = nil
        step = hasCandidates ? .choose : .protect(.new)
        if hasCandidates, cloud?.availability != .ready, probeTask == nil {
            launchProbe()
        }
    }

    /// Create the library for the source in `.protect`, keyed with
    /// `password` or, when nil, a fresh auto key. On success the bridge is
    /// open and the launch gate moves on.
    func createLibrary(password: String?) async -> Bool {
        guard case .protect(let source) = step else { return false }
        error = nil
        switch source {
        case .new:
            let ok = password.map { bridge.createWithPassword($0) } ?? bridge.createWithAutoKey()
            if !ok { error = bridge.connectionError ?? "Failed to create database." }
            else if let password { noteRecoveryKey(for: password) }
            return ok
        case .cloud:
            return await adoptCloud(password: password)
        case .backup:
            return false
        }
    }

    /// The backup's own password, entered at `.backupPassword`.
    func unlockBackup(password: String) async -> Bool {
        guard case .backupPassword(let id) = step else { return false }
        return await restoreBackup(id: id, key: password, password: password)
    }

    // MARK: Work

    private func adoptCloud(password: String?) async -> Bool {
        guard let cloud, let folder = cloudFolder, let key = SyncKeychain.load() else {
            error = "The iCloud copy isn't ready yet."
            return false
        }
        let previous = step
        step = .working("Downloading the iCloud copy…")
        let passphrase = RustBridge.localKeyForNewLibrary(password: password)
        let generation = cloud.generation
        let dbPath = RustBridge.databasePath()
        let outcome: Result<Void, Error> = await Task.detached(priority: .userInitiated) {
            let staged: URL
            switch CloudLibrarySync.stageCloudLibrary(in: folder) {
            case .success(let url): staged = url
            case .failure(.downloading):
                return .failure(BootstrapError.message("The iCloud copy is still downloading. Try again in a moment."))
            case .failure(.failed(let message)):
                return .failure(BootstrapError.message(message))
            }
            do {
                try libraryBootstrapFromCloud(dbPath: dbPath, stagedPath: staged.path, cloudKey: key,
                                              expectedGeneration: generation, passphrase: passphrase)
                return .success(())
            } catch {
                try? FileManager.default.removeItem(at: staged)
                return .failure(error)
            }
        }.value
        switch outcome {
        case .success:
            guard bridge.openBootstrapped(password: password) else {
                error = bridge.connectionError ?? "The iCloud copy couldn't be opened."
                step = previous
                return false
            }
            if let password { noteRecoveryKey(for: password) }
            return true
        case .failure(let e):
            error = e.localizedDescription
            step = previous
            return false
        }
    }

    @discardableResult
    private func restoreBackup(id: String, key: String, password: String?) async -> Bool {
        let previous = step
        step = .working("Restoring the backup…")
        let dbPath = RustBridge.databasePath()
        let outcome: Result<Void, Error> = await Task.detached(priority: .userInitiated) {
            do {
                try libraryBootstrapFromBackup(dbPath: dbPath, id: id, passphrase: key)
                return .success(())
            } catch {
                return .failure(error)
            }
        }.value
        switch outcome {
        case .success:
            guard bridge.openBootstrapped(password: password) else {
                error = bridge.connectionError ?? "The backup couldn't be opened."
                step = previous
                return false
            }
            if let password { noteRecoveryKey(for: password) }
            return true
        case .failure(let e):
            let message = e.localizedDescription
            if password == nil, message.contains("different library password") {
                // The auto key isn't this backup's key; ask for its password.
                step = .backupPassword(id: id)
            } else {
                error = message
                step = previous
            }
            return false
        }
    }

    /// A password-protected library gets a recovery key, shown once.
    private func noteRecoveryKey(for password: String) {
        let key = RecoveryKey.generate()
        if let blob = RecoveryKey.encryptPassword(password, withRecoveryKey: key) {
            RecoveryKey.storeEncryptedBlob(blob)
            recoveryKey = key
            bridge.showingRecoveryKey = true
        }
        RecoveryKey.resetFailureCount()
    }

    /// The user has written the recovery key down.
    func dismissRecoveryKey() {
        recoveryKey = nil
        bridge.showingRecoveryKey = false
    }

    private enum BootstrapError: LocalizedError {
        case message(String)
        var errorDescription: String? {
            switch self { case .message(let m): m }
        }
    }
}
