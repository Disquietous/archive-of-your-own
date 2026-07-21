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
    /// Parse the Retry-After seconds the Rust layer embeds in 429 errors
    /// ("HTTP 429 retry_after=300").
    static func retryAfterSeconds(in description: String) -> Int? {
        guard let range = description.range(of: "retry_after=") else { return nil }
        let digits = description[range.upperBound...].prefix { $0.isNumber }
        return Int(digits)
    }

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
        var sessionRetried = false
        var timeoutCount = 0
        var blockedCount = 0
        while !task.isCancelled {
            do {
                return try await operation()
            } catch {
                if task.isCancelled { throw error }
                let desc = "\(error)"
                if desc.contains("cancelled") { throw error }
                if desc.contains("session_expired") && !sessionRetried {
                    sessionRetried = true
                    task.statusMessage = "Session expired. Re-authenticating…"
                    let loggedIn = await bridge.ensureLoggedIn()
                    if task.isCancelled { throw error }
                    if loggedIn {
                        task.statusMessage = "Retrying…"
                        continue
                    }
                    await MainActor.run {
                        needsReauth = true
                    }
                    throw Ao3Error.Network(message: "Session expired. Please re-enter your password.")
                }
                if desc.contains("password_needed") && !sessionRetried {
                    sessionRetried = true
                    await MainActor.run {
                        needsReauth = true
                    }
                    throw Ao3Error.Network(message: "Session expired. Please re-enter your password.")
                }
                if desc.contains("timeout") {
                    timeoutCount += 1
                    if timeoutCount >= 3 {
                        throw error
                    }
                    if bridge.torStatus.isConnected {
                        task.isReconnecting = true
                        task.statusMessage = "Timed out. Getting new circuit… (\(timeoutCount)/3)"
                        await rotateCircuit()
                        if task.isCancelled { throw error }
                        task.isReconnecting = false
                        task.statusMessage = nil
                        continue
                    }
                    task.statusMessage = "Timed out. Retrying… (\(timeoutCount)/3)"
                    continue
                }
                // Rate-limited (429). The budget is per exit IP, so a fresh
                // circuit is a fresh budget — rotate rather than waiting out
                // the Retry-After window on the burned IP. Without Tor, all
                // we can do is surface an honest countdown.
                if desc.contains("HTTP 429") {
                    blockedCount += 1
                    let waitDescription = Self.retryAfterSeconds(in: desc).map { secs in
                        secs >= 120 ? "about \(Int((Double(secs) / 60).rounded())) minutes"
                                    : "about \(secs) seconds"
                    }
                    if blockedCount >= 3 {
                        throw Ao3Error.Network(message: "The archive is rate-limiting this connection. Try again in \(waitDescription ?? "a few minutes").")
                    }
                    if bridge.torStatus.isConnected {
                        task.isReconnecting = true
                        task.statusMessage = "Rate limited. Getting new circuit… (\(blockedCount)/3)"
                        await rotateCircuit()
                        if task.isCancelled { throw error }
                        task.isReconnecting = false
                        task.statusMessage = nil
                        continue
                    }
                    throw Ao3Error.Network(message: "The archive is rate-limiting this connection. Try again in \(waitDescription ?? "a few minutes"), or connect via Tor to get a fresh route.")
                }
                // Cloudflare bot rejection of this circuit/session. The fix is
                // the same as the connect flow's: a fresh circuit + a fresh
                // challenge clearance, both of which connectTor() performs.
                if desc.contains("HTTP 403") {
                    blockedCount += 1
                    if blockedCount >= 3 {
                        throw Ao3Error.Network(message: "The archive's protection blocked this connection repeatedly. Try again in a little while.")
                    }
                    if bridge.torStatus.isConnected {
                        task.isReconnecting = true
                        task.statusMessage = "Blocked by archive protection. Getting new circuit… (\(blockedCount)/3)"
                        await rotateCircuit()
                        if task.isCancelled { throw error }
                        task.isReconnecting = false
                        task.statusMessage = nil
                        continue
                    }
                    throw Ao3Error.Network(message: "The archive's protection blocked this request. Connecting via Tor lets the app clear the challenge and retry.")
                }
                throw error
            }
        }
        throw Ao3Error.Network(message: "cancelled")
    }
}
