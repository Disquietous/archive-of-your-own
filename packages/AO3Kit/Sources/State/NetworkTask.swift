import SwiftUI

@Observable
final class NetworkTask {
    var isCancelled = false
    var statusMessage: String?
    var isReconnecting = false

    func cancel() {
        isCancelled = true
        statusMessage = nil
        isReconnecting = false
    }

    func reset() {
        isCancelled = false
        statusMessage = nil
        isReconnecting = false
    }
}

extension AppState {
    /// Run `operation`, tracking it as a user-initiated fetch. Connectivity
    /// policy — whether to rotate, back off, or re-clear Cloudflare — lives
    /// entirely in the Rust recovery engine now (`core/src/api/recovery.rs`):
    /// by the time an error reaches here, the engine has already retried
    /// everything it safely could. This wrapper only handles what's left,
    /// which isn't a connectivity decision: user cancellation, and the
    /// re-auth prompt for a session the engine can't repair on its own.
    /// Live status while the engine is mid-recovery is `AppState.
    /// currentRecovery`, projected from its event stream — see
    /// AppState+Recovery.swift and NetworkLoadingView.
    func retryOnTimeout<T>(task: NetworkTask, using bridge: RustBridge, _ operation: () async throws -> T) async throws -> T {
        if bridge.networkBlocked {
            let connected = await ensureTorConnected()
            if !connected {
                throw Ao3Error.Network(message: "Tor connection failed. Try again or disable Tor in Settings.")
            }
        }
        // Mark a user-initiated fetch in flight — the subscription checker
        // yields between its items while this counter is non-zero.
        await MainActor.run { activeUserFetches += 1 }
        defer {
            Task { @MainActor in self.activeUserFetches -= 1 }
        }
        task.reset()
        do {
            return try await operation()
        } catch {
            if task.isCancelled || error.isCancellation { throw Ao3Error.Cancelled }
            // Never probe or silently repair login state — the Rust layer
            // has already purged the cached token; surface the manual
            // sign-in prompt and stop.
            if error.isSessionExpired || error.isPasswordNeeded {
                await MainActor.run { needsReauth = true }
                throw Ao3Error.Network(message: "Session expired. Please sign in again.")
            }
            throw error
        }
    }
}
