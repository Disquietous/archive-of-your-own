import Foundation

/// Bridges Rust's connection-recovery event stream into `AppState`.
/// Registered once per live `Ao3App` instance (see `RustBridge.
/// registerRecoveryHooks`); Rust invokes `onEvent` only from its dispatcher
/// task, never mid-request, but always hop to the main actor before
/// touching `AppState` — this method is the one place that happens.
final class RecoveryObserver: CoreObserver, @unchecked Sendable {
    private weak var state: AppState?

    init(state: AppState) {
        self.state = state
    }

    func onEvent(event: CoreEvent) {
        Task { @MainActor [weak state] in
            state?.handleRecoveryEvent(event)
        }
    }
}

/// The recovery engine's `PlatformCapabilities` implementation: Cloudflare
/// clearance via a hidden WKWebView. Separate from `resolveCloudflare()`
/// (`AppState+Tor.swift`), which drives the connect flow's own UI state —
/// this is the automatic, mid-request path the engine calls without any
/// user-visible flow of its own.
final class RecoveryCapabilities: PlatformCapabilities, @unchecked Sendable {
    func earnCloudflareClearance(socksPort: UInt16) async throws -> [String] {
        let resolver = await CloudflareResolver()
        do {
            let resolved = try await resolver.resolve(socksPort: socksPort)
            return resolved.cookies
        } catch {
            throw CapabilityError.Failed(message: "\(error)")
        }
    }
}

@MainActor
extension AppState {
    /// What the recovery engine is currently doing, for `NetworkLoadingView`.
    /// One shared status (not per-operation) — the UI only ever shows one
    /// loading view at a time, and the engine only ever recovers one
    /// operation at a time in practice (requests are effectively serial
    /// against a single client).
    struct RecoveryStatus: Equatable {
        var kind: OpKind
        var failure: FailureKind
        var remedy: Remedy
        var attempt: UInt32
        var maxAttempts: UInt32
        var step: RecoveryStep?
    }

    /// Byte-level progress of whatever operation last reported it — the
    /// event-driven replacement for the old `getFetchProgress` poll.
    struct ProgressStatus: Equatable {
        var kind: OpKind
        var phase: OpPhase
        var bytes: UInt64
        var total: UInt64?
    }

    func handleRecoveryEvent(_ event: CoreEvent) {
        switch event {
        case .recoveryStarted(let id, let failure, let remedy, let attempt, let maxAttempts):
            recoveringOperationID = id
            currentRecovery = RecoveryStatus(
                kind: operationKinds[id] ?? .fetch(label: ""),
                failure: failure, remedy: remedy, attempt: attempt, maxAttempts: maxAttempts, step: nil)

        case .recoveryStep(let id, let step):
            guard id == recoveringOperationID else { return }
            currentRecovery?.step = step
            if step == .rotatingCircuit {
                // Rotation happens entirely inside Rust now — Swift's old
                // rotateCircuit() (AppState+Tor.swift) used to be the only
                // path that ever called this, so every automatic rotation
                // refreshed the circuit display for free. That path is dead
                // now; this is its replacement, so the privacy pill doesn't
                // go stale until something else (e.g. hover) happens to
                // trigger a refresh.
                bridge.refreshCircuitHops()
            }

        case .operationStarted(let id, let kind):
            operationKinds[id] = kind

        case .operationProgress(let id, let phase, let bytes, let total):
            progressOperationID = id
            currentProgress = ProgressStatus(kind: operationKinds[id] ?? .fetch(label: ""), phase: phase, bytes: bytes, total: total)

        case .operationFinished(let id, let outcome):
            let wasRecovering = (id == recoveringOperationID)
            operationKinds.removeValue(forKey: id)
            if id == recoveringOperationID {
                recoveringOperationID = nil
                currentRecovery = nil
            }
            if id == progressOperationID {
                progressOperationID = nil
                currentProgress = nil
            }
            // A recovered operation's retry ran on a freshly rotated
            // circuit — refresh again now that real traffic has actually
            // flowed on it (the mid-rotation refresh above may have caught
            // the new circuit before it carried anything).
            if wasRecovering, case .succeeded = outcome {
                bridge.refreshCircuitHops()
            }

        case .operationTick, .connectionChanged, .dataInvalidated:
            break
        }
    }
}
