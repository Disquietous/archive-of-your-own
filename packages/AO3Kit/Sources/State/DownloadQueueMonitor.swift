import Foundation

/// Live, observable picture of the core's download queue (the content
/// queue) for a monitor UI: what the worker is doing, the work in
/// flight, and everything still queued. Written only by
/// `AppState.refreshDownloadQueue`; the core is the authority and this
/// mirrors it.
@Observable
@MainActor
final class DownloadQueueMonitor {
    private(set) var state: ContentQueueState = .idle
    /// The user's pause, whether or not the in-flight work has finished.
    private(set) var paused = false
    /// The work in flight, when one is.
    private(set) var current: UContentQueueItem?
    private(set) var currentStartedAt: Date?
    /// Due works, in the order the worker takes them (the one in flight
    /// left out).
    private(set) var upNext: [UContentQueueItem] = []
    /// Works held back until a retry time.
    private(set) var held: [UContentQueueItem] = []
    /// Works left alone after their last allowed failure.
    private(set) var gaveUp: [UContentQueueItem] = []

    /// The requests the work in flight needs, as far as the core knows
    /// them, in order. Empty between works.
    private(set) var steps: [UContentQueueStep] = []

    /// A monitor UI is showing: the queue's contents are only read from
    /// the library while one is.
    var isWatched = false

    var queuedCount: Int { upNext.count + held.count + gaveUp.count + (current == nil ? 0 : 1) }

    func update(status: UContentQueueStatus, items: [UContentQueueItem]?, steps: [UContentQueueStep]) {
        self.steps = status.currentWorkId == nil ? [] : steps
        state = status.state
        paused = status.paused
        currentStartedAt = status.currentStartedAt.map { Date(timeIntervalSince1970: TimeInterval($0)) }
        guard let items else {
            if status.currentWorkId == nil { current = nil }
            return
        }
        let now = UInt64(Date().timeIntervalSince1970)
        var next: [UContentQueueItem] = []
        var waiting: [UContentQueueItem] = []
        var parked: [UContentQueueItem] = []
        var inFlight: UContentQueueItem?
        for item in items {
            if item.workId == status.currentWorkId {
                inFlight = item
            } else if item.attempts >= item.maxAttempts {
                parked.append(item)
            } else if item.retryAt > now {
                waiting.append(item)
            } else {
                next.append(item)
            }
        }
        current = inFlight
        upNext = next
        held = waiting
        gaveUp = parked
    }
}
