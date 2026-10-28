import SwiftUI

// MARK: - What's New: the follows check, its monitor controls, the feed

extension AppState {
    /// Refresh the per-follow last-checked stamps (keyed "kind:target_id",
    /// lowercased) from the follows table.
    /// Also refreshes which follows are currently not found.
    func loadFollowLastChecked() {
        var map: [String: String] = [:]
        var notFound: Set<String> = []
        for f in bridge.getFollows() {
            let key = "\(f.kind):\(f.targetId.lowercased())"
            if let at = f.lastCheckedAt { map[key] = at }
            if f.status != 0 { notFound.insert(key) }
        }
        followLastChecked = map
        followNotFound = notFound
    }

    /// Run the What's New check over the follows. `force` checks every
    /// follow regardless of per-row freshness (the user asked explicitly);
    /// the default lets each row's own last-checked stamp decide, so a
    /// resumed round re-checks only what actually needs it.
    /// `olderThanSecs` limits the round to follows last checked longer ago
    /// than that, or never (the overdue warning's "check just these").
    func runWhatsNewCheck(force: Bool = false, olderThanSecs: UInt64? = nil) async {
        guard ao3Username != nil else { return }
        guard !isCheckingWhatsNew else { return }
        // Claim the check BEFORE the first await. Waiting for Tor can take
        // a minute; a second caller arriving in that window (the toolbar
        // button, a library replacement re-running the auto-check) used to
        // pass the guard and start a second loop over the same queue.
        isCheckingWhatsNew = true
        checkMonitor.begin()

        if bridge.networkBlocked {
            guard await ensureTorConnected() else {
                isCheckingWhatsNew = false
                checkMonitor.end(error: "Tor did not connect.")
                return
            }
        }

        whatsNewCheckTask.reset()
        whatsNewCheckFailed = 0
        // Notification count = entries that will badge as "New", so the
        // alert, the sidebar/dock count, and the list agree.
        let unseenBefore = unseenNewWorkIDs

        do {
            // The queue is built from the follows in the shared Rust store,
            // so follows added on any platform are checked here.
            let total = try bridge.startWhatsNewCheck(onlyStale: !force, olderThanSecs: olderThanSecs)
            whatsNewCheckTotal = Int(total)
            whatsNewCheckRemaining = Int(total)
            checkMonitor.queued(bridge.getWhatsNewCheckQueue())

            while !whatsNewCheckTask.isCancelled {
                if await holdBetweenChecks() { break }
                checkMonitor.setPhase(.running)

                let queue = bridge.getWhatsNewCheckQueue()
                checkMonitor.queued(queue)
                guard let head = queue.first else { break }
                checkMonitor.dispatched(head)
                if checkMonitor.stopRequested { checkMonitor.setPhase(.stopping) }

                guard let result = try await bridge.checkNextFollow() else {
                    checkMonitor.dispatched(nil)
                    break
                }
                handleCheckResult(result, head: head)
            }

            if !whatsNewCheckTask.isCancelled {
                loadNotifications()
                let added = unseenNewWorkIDs.subtracting(unseenBefore).count
                if added > 0 {
                    onNewWorksFound?(added)
                }
            }
        } catch {
            if !whatsNewCheckTask.isCancelled {
                let msg = "Check failed: \(Self.readableError(error))"
                whatsNewCheckTask.statusMessage = msg
                checkMonitor.end(error: msg)
            }
        }
        if whatsNewCheckFailed > 0 {
            whatsNewCheckTask.statusMessage = "\(whatsNewCheckFailed) follow\(whatsNewCheckFailed == 1 ? "" : "s") failed to check"
        }
        isCheckingWhatsNew = false
        whatsNewCheckTotal = 0
        whatsNewCheckRemaining = 0
        checkMonitor.queued(bridge.getWhatsNewCheckQueue())
        if checkMonitor.isRunning { checkMonitor.end() }
    }

    /// Hold between items while the user is fetching something (never
    /// compete for the circuit or the rate limiter) or while the monitor's
    /// Pause is down. Returns true when the check was cancelled/stopped and
    /// the loop must end.
    private func holdBetweenChecks() async -> Bool {
        var held = false
        while !whatsNewCheckTask.isCancelled
                && (activeUserFetches > 0 || checkMonitor.pauseRequested) {
            if checkMonitor.stopRequested { whatsNewCheckTask.cancel() ; break }
            if !held {
                held = true
                whatsNewCheckTask.statusMessage = checkMonitor.pauseRequested
                    ? "Paused." : "Paused while you browse…"
            }
            checkMonitor.setPhase(checkMonitor.pauseRequested ? .pausedByUser : .pausedForBrowsing)
            try? await Task.sleep(nanoseconds: 500_000_000)
        }
        if checkMonitor.stopRequested { whatsNewCheckTask.cancel() }
        if whatsNewCheckTask.isCancelled { return true }
        if held {
            whatsNewCheckTask.statusMessage = nil
        }
        return false
    }

    /// Fold one finished follow check into the monitor and the feeds.
    private func handleCheckResult(_ result: UFollowCheckResult, head: UCheckQueueItem) {
        whatsNewCheckRemaining = Int(result.remaining)
        // Each completed check stamped its row — keep list labels live.
        loadFollowLastChecked()

        let finishedItem = UCheckQueueItem(
            kind: result.kind, targetId: result.targetId, name: result.name, census: head.census,
            page: head.page, totalPages: head.totalPages)
        if let error = result.error {
            // A transient failure already got rotated-and-retried in
            // Rust before this returned — nothing left for Swift to
            // decide. A still-retryable item was requeued for later
            // in this cycle (reflected in `remaining`); this just
            // counts the attempt and moves to the next item.
            whatsNewCheckFailed += 1
            checkMonitor.finished(finishedItem, .failed(error))
        } else {
            checkMonitor.finished(finishedItem, result.changed ? .updated : .unchanged)
            if result.changed {
                loadNewWorks()
                reloadCachedWorks()
                // work(byID:) consults fetchedWorks before the
                // cachedWorks snapshot — a copy viewed earlier this
                // session would shadow the freshly saved row, so
                // replace any flagged entries from the DB.
                for id in newWorkIDs where fetchedWorks[id] != nil {
                    if let workId = UInt64(id),
                       let fresh = bridge.getCachedWork(workId) {
                        fetchedWorks[id] = Self.workFromSummary(fresh)
                    }
                }
            }
        }
    }

    // MARK: - Monitor controls

    /// Start a run: resume a leftover queue and everything that is due, or
    /// with `all`, clear the queue and check every follow.
    func startWhatsNewCheck(all: Bool) {
        guard !isCheckingWhatsNew else { return }
        if all { bridge.resetWhatsNewCheck() }
        Task { await runWhatsNewCheck(force: all) }
    }

    /// The overdue warning's "check just these": a round over only the
    /// follows last checked over `whatsNewOverdueSecs` ago, or never.
    func startOverdueWhatsNewCheck() {
        guard !isCheckingWhatsNew else { return }
        Task { await runWhatsNewCheck(olderThanSecs: Self.whatsNewOverdueSecs) }
    }

    /// The overdue warning's text, with its counts.
    var whatsNewOverdueMessage: String {
        guard let counts = whatsNewOverdueCounts, counts.overdue > 0 else {
            return "Some followed authors, works or series haven’t been checked in over 24 hours."
        }
        let n = Int(counts.overdue)
        var text = n == 1
            ? "1 followed author, work or series hasn’t been checked in over 24 hours"
            : "\(n) followed authors, works or series haven’t been checked in over 24 hours"
        let never = Int(counts.neverChecked)
        if never > 0 {
            text += never == n
                ? (n == 1 ? " — it has never been checked" : " — none of them has ever been checked")
                : " (\(never) never checked)"
        }
        return text + "."
    }

    /// The "check just these" button title, e.g. "Check These 12".
    var whatsNewOverdueCheckTitle: String {
        let n = Int(whatsNewOverdueCounts?.overdue ?? 0)
        return n == 1 ? "Check This One" : "Check These \(n)"
    }

    /// Hold the run at the next item boundary. The in-flight request
    /// finishes; nothing new is dispatched until `resumeWhatsNewCheck`.
    func pauseWhatsNewCheck() {
        guard isCheckingWhatsNew else { return }
        checkMonitor.pauseRequested = true
    }

    func resumeWhatsNewCheck() {
        checkMonitor.pauseRequested = false
    }

    /// End the run. The queue stays persisted, so the next Start resumes
    /// where this left off. The in-flight request is aborted when nothing
    /// of the user's is in flight; otherwise it is left to finish.
    func stopWhatsNewCheck() {
        guard isCheckingWhatsNew else { return }
        checkMonitor.stopRequested = true
        checkMonitor.pauseRequested = false
        checkMonitor.setPhase(.stopping)
        whatsNewCheckTask.cancel()
        if activeUserFetches == 0 {
            bridge.cancelRequest()
        }
    }

    func loadNewWorks() {
        newWorkIDs = bridge.getNewWorkIds().map { String($0) }
        unseenNewWorkIDs = Set(bridge.getUnseenNewWorkIds().map { String($0) })
        goneWorkIDs = Set(bridge.getGoneWorkIds().map { String($0) })
        finishedWorkIDs = Set(bridge.getFinishedWorkIds().map { String($0) })
        detailViewedWorkIDs = Set(bridge.getDetailViewedWorkIds().map { String($0) })
    }

    /// Selecting a What's New entry clears its "New" badge (and drops it
    /// from the sidebar/dock count). No-op for works not in the feed.
    func markNewWorkSeen(_ id: String) {
        guard unseenNewWorkIDs.contains(id) else { return }
        unseenNewWorkIDs.remove(id)
        if let workId = UInt64(id) {
            bridge.markNewWorkSeen(workId)
        }
    }

    func removeNewWork(_ id: String) {
        if let workId = UInt64(id) {
            bridge.removeNewWork(workId)
        }
        newWorkIDs.removeAll { $0 == id }
        unseenNewWorkIDs.remove(id)
    }

    func clearNewWorks() {
        bridge.clearNewWorks()
        newWorkIDs = []
        unseenNewWorkIDs = []
    }
}
