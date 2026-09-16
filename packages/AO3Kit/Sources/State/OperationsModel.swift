import Foundation
import Observation

/// Everything the app is fetching right now, as human-readable lines for
/// summarized loading feedback (a status bar, a banner). Combines the
/// shared AppState flags with the hoisted models' own operations.
@Observable
@MainActor
final class OperationsModel {
    let appState: AppState
    let search: SearchModel
    let author: AuthorProfileModel
    let subscriptionWorks: SubscriptionWorksModel

    init(appState: AppState, search: SearchModel, author: AuthorProfileModel,
         subscriptionWorks: SubscriptionWorksModel) {
        self.appState = appState
        self.search = search
        self.author = author
        self.subscriptionWorks = subscriptionWorks
    }

    var inFlightOperations: [String] {
        var ops: [String] = []
        if let recovery = appState.currentRecovery { ops.append(Self.recoveryStatusText(recovery)) }
        if appState.isTestingCircuit { ops.append("Testing Tor circuit \(appState.circuitAttempt)") }
        if appState.isResolvingCloudflare { ops.append("Clearing archive challenge") }
        if appState.isSearching { ops.append("Searching the archive") }
        if appState.isLoadingSubscriptions { ops.append("Loading your subscription list") }
        if appState.isCheckingSubscriptions {
            let done = appState.subscriptionCheckTotal - appState.subscriptionCheckRemaining
            if appState.subscriptionCheckTotal > 0 {
                ops.append("Checking subscriptions (\(done)/\(appState.subscriptionCheckTotal))")
            } else {
                ops.append("Checking subscriptions")
            }
        }
        if subscriptionWorks.isLoading {
            ops.append("Fetching \(subscriptionWorks.title ?? "author")’s works")
        }
        if author.isLoadingWorks { ops.append("Fetching \(author.username ?? "author")’s works") }
        if search.isLoadingForm { ops.append("Loading search criteria") }
        if let sync = appState.bookmarkSyncTask.statusMessage { ops.append(sync) }
        return ops
    }

    /// Names the recovery engine's remedy honestly.
    static func recoveryStatusText(_ recovery: AppState.RecoveryStatus) -> String {
        let attempt = "(\(recovery.attempt) of \(recovery.maxAttempts))"
        switch recovery.step {
        case .earningClearance:
            return "Passing the archive's connection check… \(attempt)"
        case .backingOff(let seconds):
            return "Archive temporarily unavailable — waiting \(seconds)s… \(attempt)"
        case .reconnecting:
            return "Rebuilding the Tor connection… \(attempt)"
        case .rotatingCircuit, .retrying, nil:
            break
        }
        switch recovery.remedy {
        case .rotate, .rotateAndReclear:
            return "Archive connection failed — trying a new route… \(attempt)"
        case .backoff:
            return "Archive temporarily unavailable — retrying… \(attempt)"
        case .reconnect:
            return "Rebuilding the Tor connection… \(attempt)"
        case .purge:
            return "Session expired — please sign in again"
        }
    }
}
