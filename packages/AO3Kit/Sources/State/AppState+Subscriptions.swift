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

        if bridge.networkBlocked {
            guard await ensureTorConnected() else { return }
        }

        isCheckingSubscriptions = true
        subscriptionCheckTask.reset()
        subscriptionCheckFailed = 0
        let newWorksBefore = Set(newWorkIDs)

        do {
            // Device-local follows join the check queue alongside real AO3
            // subscriptions — read from the shared Rust store, so follows
            // added on any platform are checked here.
            let follows = bridge.getFollowed(kind: "author")
            let total = try bridge.startSubscriptionCheck(extraAuthors: follows, onlyStale: !force)
            subscriptionCheckTotal = Int(total)
            subscriptionCheckRemaining = Int(total)

            while !subscriptionCheckTask.isCancelled {
                // Yield to the user: while they're actively fetching something,
                // pause between items so the background check never competes
                // for the circuit or the rate limiter.
                var pausedForUser = false
                while activeUserFetches > 0 && !subscriptionCheckTask.isCancelled {
                    if !pausedForUser {
                        pausedForUser = true
                        subscriptionCheckTask.statusMessage = "Paused while you browse…"
                    }
                    try? await Task.sleep(nanoseconds: 500_000_000)
                }
                if subscriptionCheckTask.isCancelled { break }
                if pausedForUser {
                    subscriptionCheckTask.statusMessage = nil
                }

                guard let result = try await bridge.checkNextSubscription() else { break }
                subscriptionCheckRemaining = Int(result.remaining)
                // Each completed check stamped its row — keep list labels live.
                loadSubscriptionLastChecked()

                if result.error != nil {
                    // A transient failure already got rotated-and-retried in
                    // Rust before this returned — nothing left for Swift to
                    // decide. A still-retryable item was requeued for later
                    // in this cycle (reflected in `remaining`); this just
                    // counts the attempt and moves to the next item.
                    subscriptionCheckFailed += 1
                } else {
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
                let added = newWorkIDs.filter { !newWorksBefore.contains($0) }.count
                if added > 0 {
                    onNewWorksFound?(added)
                }
            }
        } catch {
            if !subscriptionCheckTask.isCancelled {
                subscriptionCheckTask.statusMessage = "Check failed: \(Self.readableError(error))"
            }
        }
        if subscriptionCheckFailed > 0 {
            subscriptionCheckTask.statusMessage = "\(subscriptionCheckFailed) subscription\(subscriptionCheckFailed == 1 ? "" : "s") failed to fetch"
        }
        isCheckingSubscriptions = false
        subscriptionCheckTotal = 0
        subscriptionCheckRemaining = 0
    }

    func loadNewWorks() {
        newWorkIDs = bridge.getNewWorkIds().map { String($0) }
        goneWorkIDs = Set(bridge.getGoneWorkIds().map { String($0) })
        detailViewedWorkIDs = Set(bridge.getDetailViewedWorkIds().map { String($0) })
    }

    func removeNewWork(_ id: String) {
        if let workId = UInt64(id) {
            bridge.removeNewWork(workId)
        }
        newWorkIDs.removeAll { $0 == id }
    }

    func clearNewWorks() {
        bridge.clearNewWorks()
        newWorkIDs = []
    }

    func reloadCachedWorks() {
        cachedWorks = bridge.getAllCachedWorks().map(Self.workFromSummary)
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
