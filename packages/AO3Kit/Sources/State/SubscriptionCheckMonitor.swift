import Foundation

/// Live, observable picture of the What's New check for a monitor UI:
/// what phase the run is in, which item is in flight, what is still
/// queued, and what each finished item came back with. Written only by
/// `AppState.checkSubscriptions`; read by any platform's monitor window.
@Observable
@MainActor
public final class SubscriptionCheckMonitor {
    public enum Phase: Equatable {
        /// No run in progress.
        case idle
        /// Claimed the check, waiting for Tor to come up.
        case connecting
        /// Working through the queue.
        case running
        /// User pressed Pause; the loop holds between items.
        case pausedByUser
        /// Holding between items because the user is fetching something.
        case pausedForBrowsing
        /// Stop requested; finishing the in-flight item, then exiting.
        case stopping
    }

    public enum Outcome: Equatable {
        /// Fetched; new or updated works were flagged.
        case updated
        /// Fetched; nothing new.
        case unchanged
        /// The fetch failed after the core's own retries.
        case failed(String)
    }

    public struct Completed: Identifiable, Equatable {
        public let id: Int
        public let item: UCheckQueueItem
        public let outcome: Outcome
        public let finishedAt: Date
    }

    public private(set) var phase: Phase = .idle
    /// The item whose request is in flight (nil between items and when idle).
    public private(set) var current: UCheckQueueItem?
    /// When `current` was dispatched, for an elapsed readout.
    public private(set) var currentStartedAt: Date?
    /// What is still queued, front item first, as the core has it.
    public private(set) var pending: [UCheckQueueItem] = []
    /// Everything finished in this run, newest last.
    public private(set) var completed: [Completed] = []
    /// Size of the queue when the run started (or when it last grew).
    public private(set) var total: Int = 0
    public private(set) var startedAt: Date?
    public private(set) var finishedAt: Date?
    /// Set when the run ended on an error outside any single item.
    public private(set) var runError: String?

    /// Pause/stop requests from the UI; the loop honors them between items.
    public var pauseRequested = false
    public var stopRequested = false

    private var nextID = 0

    public init() {}

    public var isRunning: Bool { phase != .idle }
    public var updatedCount: Int { completed.filter { $0.outcome == .updated }.count }
    public var failedCount: Int {
        completed.filter { if case .failed = $0.outcome { return true } else { return false } }.count
    }
    public var doneCount: Int { completed.count }
    /// 0…1 progress through the run; nil when nothing is queued yet.
    public var fraction: Double? {
        guard total > 0 else { return nil }
        return min(1, Double(doneCount) / Double(total))
    }

    // MARK: - Loop hooks

    func begin() {
        phase = .connecting
        current = nil
        currentStartedAt = nil
        pending = []
        completed = []
        total = 0
        startedAt = Date()
        finishedAt = nil
        runError = nil
        pauseRequested = false
        stopRequested = false
    }

    func queued(_ items: [UCheckQueueItem]) {
        pending = items
        // A census can push items back in; never let total fall below
        // what has already been done plus what is still queued.
        total = max(total, completed.count + items.count)
        if phase == .connecting { phase = .running }
    }

    func setPhase(_ p: Phase) { phase = p }

    func dispatched(_ item: UCheckQueueItem?) {
        current = item
        currentStartedAt = item == nil ? nil : Date()
    }

    func finished(_ item: UCheckQueueItem, _ outcome: Outcome) {
        nextID += 1
        completed.append(Completed(id: nextID, item: item, outcome: outcome, finishedAt: Date()))
        current = nil
        currentStartedAt = nil
    }

    func end(error: String? = nil) {
        phase = .idle
        current = nil
        currentStartedAt = nil
        finishedAt = Date()
        runError = error
        pauseRequested = false
        stopRequested = false
    }
}
