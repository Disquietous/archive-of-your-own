import SwiftUI

// MARK: - Subscriptions, What's New & notifications

extension AppState {
    func isSubscribedToWork(_ id: String) -> Bool {
        subscriptions.contains { $0.id == id && $0.subType.lowercased().contains("work") }
    }

    func toggleWorkSubscription(_ id: String) {
        guard let workId = UInt64(id), !subscriptionTogglingWorkIDs.contains(id) else { return }
        subscriptionTogglingWorkIDs.insert(id)
        Task { @MainActor in
            if (try? await bridge.toggleWorkSubscription(workId: workId, username: ao3Username)) != nil {
                // The Rust side already updated the subscriptions table —
                // refresh the in-memory list from it.
                subscriptions = bridge.getPersistedSubscriptions()
            }
            subscriptionTogglingWorkIDs.remove(id)
        }
    }

    /// Refresh the per-row last-checked stamps from the snapshot table.
    func loadSubscriptionLastChecked() {
        subscriptionLastChecked = bridge.getSubscriptionLastChecked()
    }

    func loadSubscriptions(force: Bool = false) async {
        guard let username = ao3Username else {
            subscriptionError = "Sign in to AO3 in Settings first"
            return
        }
        guard !isLoadingSubscriptions else { return }

        let accountChanged = subscriptionsLoadedForAccount != username
        let shouldForce = force || accountChanged

        if !shouldForce {
            let persisted = bridge.getPersistedSubscriptions()
            if !persisted.isEmpty {
                subscriptions = persisted
                subscriptionsLoadedForAccount = username
                return
            }
        }

        isLoadingSubscriptions = true
        subscriptionError = nil
        subscriptionLoadTask.reset()
        defer { isLoadingSubscriptions = false }

        do {
            subscriptions = try await retryOnTimeout(task: subscriptionLoadTask, using: bridge) {
                try await self.bridge.fetchSubscriptions(username: username)
            }
            subscriptionsLoadedForAccount = username
            try bridge.persistSubscriptions(subscriptions)
        } catch {
            if !subscriptionLoadTask.isCancelled && !error.isCancellation {
                subscriptionError = Self.readableError(error)
            }
        }
    }

    /// `force` checks every subscription regardless of per-row freshness
    /// (the user asked explicitly); the default lets each row's own
    /// last-checked stamp decide, so a resumed round re-checks only what
    /// actually needs it.
    func checkSubscriptions(force: Bool = false) async {
        guard ao3Username != nil else { return }
        guard !isCheckingSubscriptions else { return }
        // Claim the check BEFORE the first await. Waiting for Tor can take
        // a minute; a second caller arriving in that window (the toolbar
        // button, a library replacement re-running the auto-check) used to
        // pass the guard and start a second loop over the same queue.
        isCheckingSubscriptions = true
        checkMonitor.begin()

        if bridge.networkBlocked {
            guard await ensureTorConnected() else {
                isCheckingSubscriptions = false
                checkMonitor.end(error: "Tor did not connect.")
                return
            }
        }

        subscriptionCheckTask.reset()
        subscriptionCheckFailed = 0
        // Notification count = entries that will badge as "New", so the
        // alert, the sidebar/dock count, and the list agree.
        let unseenBefore = unseenNewWorkIDs

        do {
            // Device-local follows join the check queue alongside real AO3
            // subscriptions — read from the shared Rust store, so follows
            // added on any platform are checked here.
            let follows = bridge.getFollowed(kind: "author")
            let total = try bridge.startSubscriptionCheck(extraAuthors: follows, onlyStale: !force)
            subscriptionCheckTotal = Int(total)
            subscriptionCheckRemaining = Int(total)
            checkMonitor.queued(bridge.getSubscriptionCheckQueue())

            while !subscriptionCheckTask.isCancelled {
                // Hold between items while the user is fetching something
                // (never compete for the circuit or the rate limiter) or
                // while the monitor's Pause is down. Stop is honored here
                // too, so it takes effect at the next item boundary.
                var held = false
                while !subscriptionCheckTask.isCancelled
                        && (activeUserFetches > 0 || checkMonitor.pauseRequested) {
                    if checkMonitor.stopRequested { subscriptionCheckTask.cancel() ; break }
                    if !held {
                        held = true
                        subscriptionCheckTask.statusMessage = checkMonitor.pauseRequested
                            ? "Paused." : "Paused while you browse…"
                    }
                    checkMonitor.setPhase(checkMonitor.pauseRequested ? .pausedByUser : .pausedForBrowsing)
                    try? await Task.sleep(nanoseconds: 500_000_000)
                }
                if checkMonitor.stopRequested { subscriptionCheckTask.cancel() }
                if subscriptionCheckTask.isCancelled { break }
                if held {
                    subscriptionCheckTask.statusMessage = nil
                }
                checkMonitor.setPhase(.running)

                let queue = bridge.getSubscriptionCheckQueue()
                checkMonitor.queued(queue)
                guard let head = queue.first else { break }
                checkMonitor.dispatched(head)
                if checkMonitor.stopRequested { checkMonitor.setPhase(.stopping) }

                guard let result = try await bridge.checkNextSubscription() else {
                    checkMonitor.dispatched(nil)
                    break
                }
                subscriptionCheckRemaining = Int(result.remaining)
                // Each completed check stamped its row — keep list labels live.
                loadSubscriptionLastChecked()

                let finishedItem = UCheckQueueItem(
                    subType: result.subType, subId: result.subId, name: result.name, census: head.census)
                if let error = result.error {
                    // A transient failure already got rotated-and-retried in
                    // Rust before this returned — nothing left for Swift to
                    // decide. A still-retryable item was requeued for later
                    // in this cycle (reflected in `remaining`); this just
                    // counts the attempt and moves to the next item.
                    subscriptionCheckFailed += 1
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

            if !subscriptionCheckTask.isCancelled {
                loadNotifications()
                let added = unseenNewWorkIDs.subtracting(unseenBefore).count
                if added > 0 {
                    onNewWorksFound?(added)
                }
            }
        } catch {
            if !subscriptionCheckTask.isCancelled {
                let msg = "Check failed: \(Self.readableError(error))"
                subscriptionCheckTask.statusMessage = msg
                checkMonitor.end(error: msg)
            }
        }
        if subscriptionCheckFailed > 0 {
            subscriptionCheckTask.statusMessage = "\(subscriptionCheckFailed) subscription\(subscriptionCheckFailed == 1 ? "" : "s") failed to fetch"
        }
        isCheckingSubscriptions = false
        subscriptionCheckTotal = 0
        subscriptionCheckRemaining = 0
        checkMonitor.queued(bridge.getSubscriptionCheckQueue())
        if checkMonitor.isRunning { checkMonitor.end() }
    }

    // MARK: - Monitor controls

    /// Start a run: resume a leftover queue and everything that is due, or
    /// with `all`, clear the queue and check every subscription.
    func startSubscriptionCheck(all: Bool) {
        guard !isCheckingSubscriptions else { return }
        if all { bridge.resetSubscriptionCheck() }
        Task { await checkSubscriptions(force: all) }
    }

    /// Hold the run at the next item boundary. The in-flight request
    /// finishes; nothing new is dispatched until `resumeSubscriptionCheck`.
    func pauseSubscriptionCheck() {
        guard isCheckingSubscriptions else { return }
        checkMonitor.pauseRequested = true
    }

    func resumeSubscriptionCheck() {
        checkMonitor.pauseRequested = false
    }

    /// End the run. The queue stays persisted, so the next Start resumes
    /// where this left off. The in-flight request is aborted when nothing
    /// of the user's is in flight; otherwise it is left to finish.
    func stopSubscriptionCheck() {
        guard isCheckingSubscriptions else { return }
        checkMonitor.stopRequested = true
        checkMonitor.pauseRequested = false
        checkMonitor.setPhase(.stopping)
        subscriptionCheckTask.cancel()
        if activeUserFetches == 0 {
            bridge.cancelRequest()
        }
    }

    func loadNewWorks() {
        newWorkIDs = bridge.getNewWorkIds().map { String($0) }
        unseenNewWorkIDs = Set(bridge.getUnseenNewWorkIds().map { String($0) })
        goneWorkIDs = Set(bridge.getGoneWorkIds().map { String($0) })
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

    /// Replace the library snapshot from the DB. The full-table read runs
    /// off the main thread; use `mergeCachedWorks` instead when the set of
    /// rewritten works is already known.
    func reloadCachedWorks() {
        // Snapshot the core handle here: the bridge is main-actor state.
        guard let app = bridge.coreApp else { return }
        Task.detached(priority: .utility) {
            let works = ((try? app.getAllCachedWorks()) ?? []).map(Self.workFromSummary)
            await MainActor.run { self.cachedWorks = works }
        }
    }

    /// Upsert freshly persisted works into the snapshot without re-reading
    /// the whole table.
    func mergeCachedWorks(_ works: [Work]) {
        guard !works.isEmpty else { return }
        var merged = cachedWorks
        var index = cachedWorksByID
        for w in works {
            if let existing = index[w.id],
               let pos = merged.firstIndex(where: { $0.id == existing.id }) {
                merged[pos] = w
            } else {
                merged.append(w)
            }
            index[w.id] = w
        }
        cachedWorks = merged
    }

    func mergeCachedWorks(_ summaries: [UWorkSummary]) {
        mergeCachedWorks(summaries.map(Self.workFromSummary))
    }

    func loadNotifications() {
        notifications = bridge.getNotifications()
        // The rows carry the read flag — counting here avoids a second
        // COUNT(read = 0) query on every load.
        unreadNotificationCount = notifications.filter { !$0.read }.count
    }

    func markNotificationRead(_ id: Int64) {
        bridge.markNotificationRead(id)
        loadNotifications()
    }

    func markAllNotificationsRead() {
        bridge.markAllNotificationsRead()
        loadNotifications()
    }
}
