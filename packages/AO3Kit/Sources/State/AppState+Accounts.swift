import SwiftUI

// MARK: - Accounts & AO3 login

extension AppState {
    /// Every source that has sign-in, with its accounts. Reads
    /// `accountsRevision`, so a view that calls this refreshes on change.
    func accountGroups() -> [UAccountGroup] {
        _ = accountsRevision
        return bridge.accountGroups()
    }

    /// Sign in on the source's own page (the platform shows it). One at a
    /// time; the error stays until the next attempt at that source.
    @discardableResult
    func signInAtSite(source: String) async -> Bool {
        guard siteSignInSource == nil else { return false }
        siteSignInSource = source
        siteSignInError = nil
        defer { siteSignInSource = nil }
        do {
            _ = try await bridge.signInAtSite(source: source)
        } catch {
            siteSignInError = (source, error.localizedDescription)
            return false
        }
        accountsRevision += 1
        return true
    }

    /// Remove an account (any source) from this device.
    func removeAccount(_ accountId: String) {
        bridge.removeAccount(accountId: accountId)
        refreshAO3Username()
    }

    func refreshAO3Username() {
        accountsRevision += 1
        let accounts = bridge.getAccounts()
        let active = accounts.first { $0.isActive }
        ao3ActiveAccount = active?.username
        ao3Username = active?.isLoggedIn == true ? active?.username : nil
        ao3AccountCount = accounts.count
        // Sign-in, sign-out and account changes all pass through here;
        // the core emptied subscriptions on any account transition.
        reloadSubscriptionsFromStorage()
    }

    /// Log an account out on this device only; the account stays listed.
    func logOut(accountId: String) async {
        let wasActive = bridge.getAccounts().contains { $0.id == accountId && $0.isActive }
        await bridge.logoutSpecificAccount(accountId: accountId)
        if wasActive { needsReauth = false }
        refreshAO3Username()
    }

    /// Log the active account in, filling or replacing its stored session.
    @discardableResult
    func logInActiveAccount(password: String) async -> Bool {
        await runAO3Login(failure: "Login failed. Check your password.") {
            try await self.bridge.reauthenticate(password: password)
        }
    }

    /// First sign-in: creates (or reuses) the account row for `username`,
    /// makes it active and stores the session there.
    @discardableResult
    func signInAO3(username: String, password: String) async -> Bool {
        await runAO3Login(failure: "Login failed. Check your username and password.") {
            guard try await self.bridge.login(username: username, password: password) else { return false }
            try self.bridge.saveAccount(username: username)
            self.bridge.saveSessionCookies()
            return true
        }
    }

    /// Log in another account and make it active.
    @discardableResult
    func addAO3Account(username: String, password: String) async -> Bool {
        await runAO3Login(failure: "Login failed. Check your credentials.") {
            _ = try await self.bridge.addAccount(username: username, password: password)
            return true
        }
    }

    /// One login at a time; the flag and error stay set until AO3 answers.
    private func runAO3Login(failure: String, _ attempt: () async throws -> Bool) async -> Bool {
        guard !ao3LoginInFlight else { return false }
        guard !bridge.networkBlocked else {
            ao3LoginError = bridge.privacyStatus.connectHint + "."
            return false
        }
        ao3LoginInFlight = true
        ao3LoginError = nil
        defer { ao3LoginInFlight = false }
        do {
            guard try await attempt() else {
                ao3LoginError = failure
                return false
            }
        } catch {
            let desc = "\(error)"
            if desc.contains("timeout") {
                ao3LoginError = "Request timed out. Try a new circuit."
            } else if desc.contains("Login failed") {
                ao3LoginError = failure
            } else {
                ao3LoginError = error.localizedDescription
            }
            return false
        }
        needsReauth = false
        refreshAO3Username()
        await loadSubscriptions(force: true)
        return true
    }

    /// Make an account the active one of its source. Switching another
    /// source's account leaves the AO3 account, and everything keyed to
    /// it, as it was.
    func switchAccount(_ accountId: String) {
        let previous = ao3ActiveAccount
        _ = bridge.switchAccount(accountId: accountId)
        // Re-derives the AO3 account state; the core emptied subscriptions
        // if the AO3 account changed (they're account data).
        refreshAO3Username()
        guard ao3ActiveAccount != previous else { return }

        if ao3Username == nil && ao3ActiveAccount != nil {
            needsReauth = true
        }

        // Invalidate per-account network data so views refetch.
        bookmarksLoadedForAccount = nil

        // Reload per-account data from storage
        bookmarkedWorkIDs = Set(bridge.getBookmarkedWorkIds().map { String($0) })
        bookmarkedSeriesIDs = Set(bridge.getBookmarkedSeriesIds().map { String($0) })

        let progressEntries = bridge.getAllProgress()
        progressMap = [:]
        for p in progressEntries {
            progressMap[String(p.workId)] = ReadingProgress(chapter: Int(p.chapter), pos: Int(p.position), chapterLen: Int(p.chapterLen))
        }
        readingIDs = Set(progressMap.keys)
        lastReadMap = Dictionary(uniqueKeysWithValues:
            bridge.getWorkLastReadTimes().map { (String($0.workId), $0.lastReadDt) })

        // Crash safety for clear-on-close: if the quit hook never ran (force
        // quit, crash), sweep the leftover history at launch instead.
        if historyMode == .clearOnClose {
            bridge.clearHistory()
        }
        var seen = Set<String>()
        history = bridge.getHistory().compactMap { entry in
            let id = String(entry.workId)
            return seen.insert(id).inserted ? id : nil
        }
        lastReadID = history.first

        refreshReadingLists()
        loadNotifications()
    }
}
