import Foundation
import CryptoKit
#if canImport(UIKit)
import UIKit
#endif

extension CloudLibrarySync {
    nonisolated static func runCycle(app: Ao3App, deviceName: String, folder: URL,
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
        guard let key = syncKey(json: json, mintKeyIfFirst: mintKeyIfFirst, result: &result) else { return result }

        let verdict: UCloudVerdict
        do {
            verdict = try app.cloudSyncEvaluate(manifestJson: json)
        } catch {
            result.outcome = .failed(error.localizedDescription)
            return result
        }
        result.checked = true

        switch verdict {
        case .noCloudCopy:
            pushIfDue(&result, app: app, deviceName: deviceName, folder: folder, key: key, force: true, lastPush: lastPush)
            result.resolutionDone = true

        case .owned(let needsPush):
            if needsPush {
                pushIfDue(&result, app: app, deviceName: deviceName, folder: folder, key: key, force: force, lastPush: lastPush)
            }
            result.resolutionDone = true

        // The core's "dismissed" mark is ignored: every check asks
        // (CloudLibrarySync.promptConflict).
        case .foreign(let name, let writtenAt, let generation, _):
            let conflict = Conflict(deviceName: name, writtenAt: Date(timeIntervalSince1970: Double(writtenAt) / 1000), generation: generation)
            if let (choice, forGeneration) = resolution {
                guard forGeneration == generation else {
                    // iCloud moved on while the user was deciding — ask again.
                    result.resolutionDone = true
                    result.outcome = .conflict(conflict)
                    return result
                }
                carryOut(choice, conflict: conflict, into: &result, app: app, deviceName: deviceName, folder: folder, key: key)
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

    /// The sync key, minting one when permitted. `nil` means the cycle
    /// stops here (with `result.outcome` already set when it's a failure).
    nonisolated private static func syncKey(json: String?, mintKeyIfFirst: Bool, result: inout CycleResult) -> String? {
        var key = SyncKeychain.load()
        if key == nil {
            if json != nil || !mintKeyIfFirst {
                result.outcome = .waitingForKey
                return nil
            }
            guard SyncKeychain.store(SyncKeychain.mint()) else {
                result.outcome = .failed("Couldn't store the sync key in iCloud Keychain.")
                return nil
            }
            key = SyncKeychain.load()
        }
        return key
    }

    nonisolated private static func pushIfDue(_ result: inout CycleResult, app: Ao3App, deviceName: String,
                                              folder: URL, key: String, force: Bool, lastPush: Date?) {
        if !force, let lastPush, Date().timeIntervalSince(lastPush) < pushInterval - intervalSlack { return }
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
    nonisolated static func push(app: Ao3App, deviceName: String, folder: URL, key: String) throws -> Int64 {
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

    nonisolated static func backup(from info: UBackupInfo) -> Backup {
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
