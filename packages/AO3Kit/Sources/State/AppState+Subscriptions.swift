import SwiftUI

// MARK: - AO3 subscriptions (the signed-in account's), library snapshot, notifications

extension AppState {
    /// Load the signed-in account's subscriptions. Without `force`, the
    /// stored list (the account's own, never another's) is used when there
    /// is one. `force` reloads from AO3 — subscription data only; follows
    /// are never changed by a reload. `userInitiated` (the refresh button)
    /// then offers one bulk "Follow All" prompt for subscriptions that
    /// have no follow (`pendingFollowAll`).
    func loadSubscriptions(force: Bool = false, userInitiated: Bool = false) async {
        guard let username = ao3Username else {
            subscriptions = []
            subscriptionError = "Sign in to AO3 in Settings first"
            return
        }
        guard !isLoadingSubscriptions else { return }

        let accountChanged = subscriptionsLoadedForAccount != username
        if !force && !accountChanged && !subscriptions.isEmpty { return }
        if !force {
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
            let fetched = try await retryOnTimeout(task: subscriptionLoadTask, using: bridge) {
                try await self.bridge.syncSubscriptions()
            }
            // The account may have changed while the fetch ran; the core
            // discards a stale result, and so does this.
            guard ao3Username == username else { return }
            subscriptions = fetched
            subscriptionsLoadedForAccount = username
            if userInitiated {
                let unfollowed = bridge.getUnfollowedSubscriptions()
                pendingFollowAll = unfollowed.isEmpty ? nil : unfollowed
            }
        } catch {
            if !subscriptionLoadTask.isCancelled && !error.isCancellation {
                subscriptionError = Self.readableError(error)
            }
        }
    }

    /// Re-read the signed-in account's stored subscriptions. Account
    /// transitions empty them in the core; this picks that up.
    func reloadSubscriptionsFromStorage() {
        let persisted = bridge.getPersistedSubscriptions()
        subscriptions = persisted
        subscriptionsLoadedForAccount = persisted.isEmpty ? nil : ao3Username
        pendingFollowAll = nil
    }

    /// The AO3 subscription for an author changed — keep a cached profile's
    /// subscribed flag in step.
    func noteAuthorSubscription(_ target: FollowModel.Target, subscribed: Bool) {
        guard target.kind == .author else { return }
        let key = target.id.lowercased()
        if var p = userProfiles[key], p.subscribed != subscribed {
            p.subscribed = subscribed
            userProfiles[key] = p
        }
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
