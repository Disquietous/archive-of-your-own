import SwiftUI

// MARK: - Accounts & AO3 login

extension AppState {
    func refreshAO3Username() {
        let active = bridge.getActiveAccountUsername()
        ao3Username = active.isEmpty ? nil : active
        ao3AccountCount = bridge.getAccounts().count
    }

    func switchAccount(_ accountId: String) {
        let result = bridge.switchAccount(accountId: accountId)
        ao3Username = result.username.isEmpty ? nil : result.username

        if !result.hasSession && !result.username.isEmpty {
            needsReauth = true
        }

        // Invalidate per-account network data so views refetch
        subscriptionsLoadedForAccount = nil
        bookmarksLoadedForAccount = nil
        subscriptions = []

        // Reload per-account data from storage
        bookmarkedWorkIDs = Set(bridge.getBookmarkedWorkIds().map { String($0) })

        let progressEntries = bridge.getAllProgress()
        progressMap = [:]
        for p in progressEntries {
            progressMap[String(p.workId)] = ReadingProgress(chapter: Int(p.chapter), pct: p.position)
        }
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

        readingLists = bridge.getReadingLists()
        loadNotifications()
    }
}
