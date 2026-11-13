import SwiftUI

// MARK: - Works, chapters, downloads & reading progress

extension AppState {
    /// The library id (as the string every screen keys by) of another
    /// work at the same source as `workID`, named by that source's own id
    /// — a series prev/next. nil when the source can't address a work by
    /// id alone or the library is unavailable.
    func rowID(forSibling externalID: String, of workID: String) -> String? {
        guard let id = UInt64(workID), let row = bridge.siblingWork(of: id, externalID: externalID) else { return nil }
        return String(row)
    }

    /// The library id of the work a link names (a subscription's target
    /// page). nil when the link isn't a work's or the library is
    /// unavailable.
    func workRowID(forLink link: String) -> String? {
        guard case .work(let id, _)? = bridge.openLink(link) else { return nil }
        return String(id)
    }

    /// The library id of the series a link names; a never-seen series is
    /// named `name` until its page is fetched.
    func seriesRowID(forLink link: String, name: String? = nil) -> String? {
        guard case .series(let id, _)? = bridge.openLink(link, nameHint: name) else { return nil }
        return String(id)
    }

    /// Force-fetch a work's current details from AO3 and replace the local
    /// copy (fetchWorkMetadata only fills gaps — this updates).
    func refreshWorkMetadata(_ id: String) async {
        guard let workId = UInt64(id), !isRefreshingWork else { return }
        isRefreshingWork = true
        defer { isRefreshingWork = false }
        do {
            let summary = try await workRefreshOp.run(bridge) { opID in
                try await retryOnTimeout(task: metadataTask, using: bridge) {
                    try await self.bridge.fetchWork(workId, opID: opID)
                }
            }
            fetchedWorks[id] = Self.workFromSummary(summary)
            // The fetched page may have revealed kudos left outside the app.
            kudosGivenWorkIDs = Set(bridge.getKudosGiven().map { String($0) })
        workReactions = Dictionary(uniqueKeysWithValues: bridge.getWorkReactions().map { (String($0.key), $0.value) })
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
        workReactions = Dictionary(uniqueKeysWithValues: bridge.getWorkReactions().map { (String($0.key), $0.value) })
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

    /// The controls for a work: its source's shapes, gates and words.
    /// nil for a row the library does not have.
    /// Whether the reader can post to a work's discussion right now, by
    /// its source's gate: hidden where the source takes no posts, disabled
    /// until that source's account is signed in. A work the core has no
    /// controls for (sample data) follows the archive login as before.
    func postGate(_ id: String) -> Gate {
        workControls(id)?.post ?? (ao3Username != nil ? .enabled : .disabled(reason: "Sign in to post"))
    }

    /// The sign-in prompt for a work's composer, naming its site.
    func postSignInPrompt(_ id: String) -> String {
        guard let site = workControls(id)?.vocabulary.siteShort, !site.isEmpty else { return "Sign in to post." }
        return "Sign in to \(site) to post."
    }

    func workControls(_ id: String) -> WorkControls? {
        _ = accountsRevision  // gates follow sign-in state
        return UInt64(id).flatMap { bridge.workControls($0) }
    }

    /// Leave kudos. One-way — kudos are permanent at the source, so there
    /// is no local toggle-off. The heart fades while the request is in
    /// flight, fills once the source confirms, and empties again (with
    /// kudosFailedWorkID set) if the source rejects it.
    func giveKudos(_ id: String) {
        guard !kudosGivenWorkIDs.contains(id) else { return }
        react(id, .kudos)
    }

    /// Set the reader's own star rating, or clear it with nil. Same
    /// pending/failed bookkeeping as kudos; the value lands when the
    /// source confirms it.
    func rateWork(_ id: String, stars: UInt8?) {
        react(id, stars.map { Reaction.stars(value: $0) } ?? .clear)
    }

    private func react(_ id: String, _ reaction: Reaction) {
        guard !kudosPendingWorkIDs.contains(id), let workId = UInt64(id) else { return }
        kudosPendingWorkIDs.insert(id)
        kudosFailedWorkID = nil
        kudosFailedIsRetryable = false
        Task { @MainActor in
            do {
                let outcome = try await kudosOp.run(bridge) { opID in
                    try await bridge.setReaction(workId: workId, reaction, opID: opID)
                }
                kudosPendingWorkIDs.remove(id)
                if outcome.accepted {
                    switch reaction {
                    case .kudos: kudosGivenWorkIDs.insert(id)
                    case .stars, .clear:
                        if let value = outcome.value { workReactions[id] = value } else { workReactions.removeValue(forKey: id) }
                    }
                } else {
                    // A genuine rejection (not signed in, own work, etc.) —
                    // the recovery engine already ruled out a transport
                    // fault before letting this surface as `false`.
                    kudosFailedWorkID = id
                    kudosFailedIsRetryable = false
                }
            } catch {
                // Reaches here only after the recovery engine exhausted
                // every retry it could safely make — a fresh attempt some
                // time later (network back, new circuit) can still succeed.
                kudosPendingWorkIDs.remove(id)
                kudosFailedWorkID = id
                kudosFailedIsRetryable = !error.isCancellation
            }
        }
    }

    /// Flip the user's finished-reading flag on one work.
    func toggleFinished(_ id: String) {
        setFinished([id], finished: !finishedWorkIDs.contains(id))
    }

    /// Set or clear the finished-reading flag on a batch of works
    /// ("mark all as read" and its undo). Sample works stay in-memory only.
    func setFinished(_ ids: [String], finished: Bool) {
        guard !ids.isEmpty else { return }
        if finished {
            finishedWorkIDs.formUnion(ids)
        } else {
            finishedWorkIDs.subtract(ids)
        }
        let real = ids.compactMap { UInt64($0) }
        if !real.isEmpty {
            bridge.setWorksFinished(real, finished: finished)
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

    /// Works in `ids` that "Download all" would fetch: real works not
    /// already offline.
    func pendingDownloads(_ ids: [String]) -> [String] {
        ids.filter { UInt64($0) != nil && !downloadedWorkIDs.contains($0) }
    }

    /// "Download all" for a list: each work not yet offline, one after
    /// another, with the core's varying 1–10 s pause before each work after
    /// the first (the same pacer that spaces a per-chapter download). Stop
    /// ends the batch after the work in flight, so nothing is left
    /// half-saved. One batch at a time.
    func downloadAll(_ ids: [String]) {
        guard bulkDownload == nil else { return }
        let pending = pendingDownloads(ids)
        guard !pending.isEmpty else { return }
        bulkDownloadStopRequested = false
        bulkDownload = BulkDownloadProgress(done: 0, total: pending.count)
        Task { @MainActor in
            for (index, id) in pending.enumerated() {
                if bulkDownloadStopRequested { break }
                if index > 0 {
                    await bridge.paceDownloadGap()
                    if bulkDownloadStopRequested { break }
                }
                if !downloadedWorkIDs.contains(id), let workId = UInt64(id) {
                    downloadedWorkIDs.insert(id)
                    bridge.markDownloaded(workId)
                    await downloadWork(id)
                }
                bulkDownload?.done += 1
            }
            bulkDownload = nil
            bulkDownloadStopRequested = false
        }
    }

    func stopBulkDownload() {
        guard bulkDownload != nil else { return }
        bulkDownloadStopRequested = true
    }

    func isDownloading(_ id: String) -> Bool {
        downloadingWorkIDs.contains(id)
    }

    func pushHistory(_ id: String) {
        // Session continuity (resume UI) works regardless of mode; the
        // history list and its persistence are what the setting governs.
        lastReadID = id
        if autoPurgeChapters, UInt64(id) != nil {
            bridge.purgeStaleChapters()
        }
        guard historyMode != .disabled else { return }
        history.removeAll { $0 == id }
        history.insert(id, at: 0)
        if let workId = UInt64(id) {
            bridge.addToHistory(workId)
        }
    }

    /// Progress is wherever the reader is NOW: revisiting chapter 1 moves the
    /// work's progress back to chapter 1. The chapter left behind lives only
    /// in the UI's in-memory return point, never here.
    func setProgress(_ id: String, chapter: Int, pos: Int, chapterLen: Int = 0) {
        // A library replacement is in flight: whatever a reader wants to
        // record now describes the library being replaced, not the one
        // about to be read from. Readers re-anchor on libraryGeneration.
        guard !isReplacingLibrary else { return }
        let existing = progressMap[id]
        // A caller that doesn't know the chapter's length (chapterLen 0)
        // must not wipe one a previous save recorded.
        let len = chapterLen > 0 ? chapterLen
            : (existing?.chapter == chapter ? existing?.chapterLen ?? 0 : 0)
        progressMap[id] = ReadingProgress(chapter: chapter, pos: pos, chapterLen: len)
        if existing == nil { readingIDs.insert(id) }
        if let workId = UInt64(id) {
            bridge.saveProgress(workId: workId, chapter: UInt32(chapter),
                                position: UInt32(max(0, pos)))
        }
    }

    func resetProgress(_ id: String) {
        progressMap.removeValue(forKey: id)
        readingIDs.remove(id)
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

/// Progress of a running "Download all".
struct BulkDownloadProgress: Equatable {
    var done: Int
    var total: Int

    /// "Downloading 3 of 12" — the work in flight is `done + 1`.
    var label: String {
        "Downloading \(min(done + 1, total)) of \(total)"
    }
}
