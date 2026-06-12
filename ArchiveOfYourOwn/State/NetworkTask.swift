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
    func retryOnTimeout<T>(task: NetworkTask, using bridge: RustBridge, _ operation: () async throws -> T) async throws -> T {
        if bridge.networkBlocked {
            throw Ao3Error.Network(message: "Tor is enabled in settings but not connected. Connect via Tor or disable it in Settings.")
        }
        task.reset()
        var sessionRetried = false
        var timeoutCount = 0
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
                    _ = await bridge.ensureLoggedIn()
                    if task.isCancelled { throw error }
                    task.statusMessage = "Retrying…"
                    continue
                }
                if desc.contains("timeout") {
                    timeoutCount += 1
                    if timeoutCount >= 3 {
                        throw error
                    }
                    if bridge.torStatus.isConnected {
                        task.isReconnecting = true
                        task.statusMessage = "Timed out. Getting new circuit… (\(timeoutCount)/3)"
                        await connectTor()
                        if task.isCancelled { throw error }
                        task.isReconnecting = false
                        task.statusMessage = nil
                        continue
                    }
                    task.statusMessage = "Timed out. Retrying… (\(timeoutCount)/3)"
                    continue
                }
                throw error
            }
        }
        throw Ao3Error.Network(message: "cancelled")
    }
}
