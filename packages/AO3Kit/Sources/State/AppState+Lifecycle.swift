import Foundation

// MARK: - Foreground / background lifecycle (iOS)
//
// iOS cannot watch input globally the way the Mac app does, so auto-lock
// is measured as time spent outside the foreground: the app stamps when it
// leaves, and on return compares the span against the user's setting.
// "Clear on close" has no reliable terminate hook on iOS either; it applies
// once the app has been away long enough to count as closed, plus the
// launch-time sweep in loadPersistedState for the force-quit case.

extension AppState {
    /// How long the app must stay backgrounded before `clearOnClose` treats
    /// that as the app having closed. Short trips to another app keep the
    /// history the user is in the middle of.
    static let clearOnCloseGraceSeconds: TimeInterval = 5 * 60

    func didEnterBackground() {
        backgroundedAt = Date()
        cloudSync.flush()
        guard bridge.isInitialized, bridge.hasDbPassword, lockOnBackground else { return }
        lockNow()
    }

    func didBecomeActive() {
        guard let since = backgroundedAt else { return }
        backgroundedAt = nil
        let elapsed = Date().timeIntervalSince(since)
        guard bridge.isInitialized else { return }
        // History goes before the lock: after lockNow the bridge is gone
        // and clearHistory would be a silent no-op (the unlock sweep
        // covers that path instead).
        if historyMode == .clearOnClose, elapsed >= Self.clearOnCloseGraceSeconds {
            clearHistory()
        }
        if autoLockMinutes > 0, bridge.hasDbPassword,
           elapsed >= Double(autoLockMinutes) * 60 {
            lockNow()
        }
    }
}
