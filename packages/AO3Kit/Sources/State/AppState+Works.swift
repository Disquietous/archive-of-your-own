import SwiftUI

// MARK: - Works, chapters, downloads & reading progress

extension AppState {
    /// Force-fetch a work's current details from AO3 and replace the local
    /// copy (fetchWorkMetadata only fills gaps — this updates).
    func refreshWorkMetadata(_ id: String) async {
        guard let workId = UInt64(id), !isRefreshingWork else { return }
        isRefreshingWork = true
        defer { isRefreshingWork = false }
        do {
            let summary = try await retryOnTimeout(task: metadataTask, using: bridge) {
                try await self.bridge.fetchWork(workId)
            }
            fetchedWorks[id] = Self.workFromSummary(summary)
            // The fetched page may have revealed kudos left outside the app.
            kudosGivenWorkIDs = Set(bridge.getKudosGiven().map { String($0) })
        } catch {
            if !metadataTask.isCancelled && !error.isCancellation {
                bridge.writeLog(level: "ERROR", tag: "work",
                                message: "Refresh failed for \(id): \(error.localizedDescription)")
            }
        }
    }

    func fetchWorkMetadata(_ id: String) async {
        guard let workId = UInt64(id), fetchedWorks[id] == nil else { return }
        // The encrypted DB is the first stop — a cached copy fills the
        // session map without a request. Only a never-cached work (or an
        // explicit refresh) touches the network.
        if let cached = bridge.getCachedWork(workId) {
            fetchedWorks[id] = Self.workFromSummary(cached)
            return
        }
        do {
            let summary = try await retryOnTimeout(task: metadataTask, using: bridge) {
                try await self.bridge.fetchWork(workId)
            }
            fetchedWorks[id] = Self.workFromSummary(summary)
            // The fetched page may have revealed kudos left outside the app.
            kudosGivenWorkIDs = Set(bridge.getKudosGiven().map { String($0) })
            // A detail open can mark before this fetch created the work's
            // row (Rust-side no-op) — re-assert now that the row exists.
            if detailViewedWorkIDs.contains(id) {
                bridge.markWorkDetailViewed(workId)
            }
        } catch {
            if !metadataTask.isCancelled && !error.isCancellation {
                searchError = error.localizedDescription
            }
        }
    }

    func chaptersForWork(_ id: String) -> [UChapter]? {
        fetchedChapters[id]
    }

    /// Leave kudos on AO3. One-way — kudos are permanent on the archive, so
    /// there is no local toggle-off. The heart fades while the request is in
    /// flight, fills fully once AO3 confirms, and empties again (with
    /// kudosFailedWorkID set) if the archive rejects it.
    func giveKudos(_ id: String) {
        guard !kudosGivenWorkIDs.contains(id), !kudosPendingWorkIDs.contains(id),
              let workId = UInt64(id) else { return }
        kudosPendingWorkIDs.insert(id)
        kudosFailedWorkID = nil
        Task { @MainActor in
            do {
                let success = try await bridge.leaveKudos(workId: workId)
                kudosPendingWorkIDs.remove(id)
                if success {
                    kudosGivenWorkIDs.insert(id)
                } else {
                    kudosFailedWorkID = id
                }
            } catch {
                kudosPendingWorkIDs.remove(id)
                kudosFailedWorkID = id
            }
        }
    }

    func toggleDownload(_ id: String) {
        if downloadedWorkIDs.contains(id) {
            downloadedWorkIDs.remove(id)
            if let workId = UInt64(id) {
                bridge.unmarkDownloaded(workId)
            }
        } else {
            downloadedWorkIDs.insert(id)
            if let workId = UInt64(id) {
                bridge.markDownloaded(workId)
                Task { await downloadWork(id) }
            }
        }
    }

    func downloadWork(_ id: String) async {
        guard let workId = UInt64(id) else { return }
        downloadingWorkIDs.insert(id)
        do {
            let chapters = try await retryOnTimeout(task: downloadTask, using: bridge) {
                try await self.bridge.fetchChapters(workId)
            }
            fetchedChapters[id] = chapters
            if let cached = bridge.getCachedWork(workId) {
                fetchedWorks[id] = Self.workFromSummary(cached)
            }
            // Complete offline reading: prefetch embedded images too
            // (over-cap and failed images are skipped, never fatal).
            await bridge.downloadWorkImages(workId: workId, maxBytes: Self.imageMaxBytesSetting)
        } catch {
            downloadedWorkIDs.remove(id)
        }
        downloadingWorkIDs.remove(id)
    }

    func isDownloading(_ id: String) -> Bool {
        downloadingWorkIDs.contains(id)
    }

    func pushHistory(_ id: String) {
        // Session continuity (resume UI) works regardless of mode; the
        // history list and its persistence are what the setting governs.
        lastReadID = id
        if UInt64(id) != nil {
            bridge.purgeStaleChapters()
        }
        guard historyMode != .disabled else { return }
        history.removeAll { $0 == id }
        history.insert(id, at: 0)
        if let workId = UInt64(id) {
            bridge.addToHistory(workId)
        }
    }

    func setProgress(_ id: String, chapter: Int, pct: Double) {
        let existing = progressMap[id]
        let highestChapter = max(chapter, existing?.chapter ?? 0)
        let storedPct = chapter == highestChapter ? pct : (existing?.pct ?? 0)
        progressMap[id] = ReadingProgress(chapter: highestChapter, pct: storedPct)
        if let workId = UInt64(id) {
            bridge.saveProgress(workId: workId, chapter: UInt32(highestChapter), position: storedPct)
        }
    }

    func resetProgress(_ id: String) {
        progressMap.removeValue(forKey: id)
        if let workId = UInt64(id) {
            bridge.deleteProgress(workId: workId)
        }
    }

    /// Called whenever a chapter of the work opens — stamps last_read_dt
    /// (Currently Reading sorts by it, latest first).
    func markWorkRead(_ id: String) {
        guard let workId = UInt64(id) else { return }
        // Mirror SQLite's datetime('now') format so in-session values sort
        // against persisted ones.
        let fmt = DateFormatter()
        fmt.dateFormat = "yyyy-MM-dd HH:mm:ss"
        fmt.timeZone = TimeZone(identifier: "UTC")
        fmt.locale = Locale(identifier: "en_US_POSIX")
        lastReadMap[id] = fmt.string(from: Date())
        bridge.markWorkRead(workId)
    }

    /// Called whenever a work's detail view opens; first view persists a
    /// timestamp and drops the work from the What's New badge count.
    func markDetailViewed(_ id: String) {
        guard !detailViewedWorkIDs.contains(id) else { return }
        detailViewedWorkIDs.insert(id)
        if let workId = UInt64(id) {
            bridge.markWorkDetailViewed(workId)
        }
    }
}
