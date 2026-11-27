import Foundation

/// One source's lane of the download queue: the queue downloads one work
/// of each source at a time, the sources side by side.
struct DownloadQueueLane: Identifiable {
    /// The source's id.
    let id: String
    /// The source's display name.
    var name: String
    var state: ContentQueueState = .idle
    /// The work in flight, when one is.
    var current: UContentQueueItem?
    var currentStartedAt: Date?
    /// Due works, in the order the lane takes them (the one in flight
    /// left out).
    var upNext: [UContentQueueItem] = []
    /// Works held back until a retry time.
    var held: [UContentQueueItem] = []
    /// Works left alone after their last allowed failure.
    var gaveUp: [UContentQueueItem] = []
    /// The requests the work in flight needs, as far as the core knows
    /// them, in order. Empty between works.
    var steps: [UContentQueueStep] = []
    /// Works finished since the lane last ran out of works to fetch.
    var completed = 0
    /// The core has a work of this source in flight.
    var inFlight = false

    var queuedCount: Int { upNext.count + held.count + gaveUp.count + (current == nil ? 0 : 1) }
    /// Works the lane still means to fetch: in flight, up next, or
    /// waiting to retry.
    var remaining: Int { upNext.count + held.count + (current == nil ? 0 : 1) }
    /// The run the lane is working through: what it has finished and
    /// what it still means to fetch — the "of 23" of "5 of 23".
    var total: Int { completed + remaining }
    /// Where the lane stands in that run — the "5" of "5 of 23": the
    /// work in flight counts, so the first work reads "1 of", and
    /// between works it is the number finished.
    var position: Int { completed + (inFlight ? 1 : 0) }
}

/// Live, observable picture of the core's download queue (the content
/// queue) for a monitor UI: what the worker is doing and, source by
/// source, the work in flight and everything still queued. Written only
/// by `AppState.refreshDownloadQueue`; the core is the authority and
/// this mirrors it.
@Observable
@MainActor
final class DownloadQueueMonitor {
    /// The queue as a whole: working while any source has a work in
    /// flight.
    private(set) var state: ContentQueueState = .idle
    /// The user's pause, whether or not the in-flight works have finished.
    private(set) var paused = false
    /// One lane for every source the queue fetches from, in the core's
    /// order, whether or not it has anything queued.
    private(set) var lanes: [DownloadQueueLane] = []

    /// A monitor UI is showing: the queue's contents are only read from
    /// the library while one is.
    var isWatched = false

    /// Some lane has a work waiting on its retry time.
    var hasHeld: Bool { lanes.contains { !$0.held.isEmpty } }

    func lane(_ sourceID: String) -> DownloadQueueLane? {
        lanes.first { $0.id == sourceID }
    }

    func update(status: UContentQueueStatus, items: [UContentQueueItem]?,
                steps: [String: [UContentQueueStep]]) {
        state = status.state
        paused = status.paused
        let previous = Dictionary(lanes.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let now = UInt64(Date().timeIntervalSince1970)
        var itemsBySource: [String: [UContentQueueItem]] = [:]
        for item in items ?? [] {
            itemsBySource[item.sourceId, default: []].append(item)
        }
        lanes = status.lanes.map { core in
            var lane = previous[core.sourceId] ?? DownloadQueueLane(id: core.sourceId, name: core.sourceName)
            lane.name = core.sourceName
            lane.state = core.state
            lane.completed = Int(core.completed)
            lane.inFlight = core.currentWorkId != nil
            lane.currentStartedAt = core.currentStartedAt.map { Date(timeIntervalSince1970: TimeInterval($0)) }
            lane.steps = core.currentWorkId == nil ? [] : (steps[core.sourceId] ?? [])
            // Without the queue's contents (no monitor showing) the lists
            // keep what they last held.
            guard items != nil else {
                if core.currentWorkId == nil { lane.current = nil }
                return lane
            }
            lane.current = nil
            lane.upNext = []
            lane.held = []
            lane.gaveUp = []
            for item in itemsBySource[core.sourceId] ?? [] {
                if item.workId == core.currentWorkId {
                    lane.current = item
                } else if item.attempts >= item.maxAttempts {
                    lane.gaveUp.append(item)
                } else if item.retryAt > now {
                    lane.held.append(item)
                } else {
                    lane.upNext.append(item)
                }
            }
            return lane
        }
    }
}
