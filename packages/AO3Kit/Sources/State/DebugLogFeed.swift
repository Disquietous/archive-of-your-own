import Foundation
import Observation

/// The debug-log viewer's window onto the log database: a filtered,
/// newest-first list that starts with one page and grows toward the oldest
/// row as the view scrolls (infinite scroll), plus a live tail that
/// prepends rows written since the newest one loaded. The filters run in
/// SQL, so a filtered view pages through matches, not through everything.
/// Nothing here deletes rows — retention is the log-trim settings' job.
@Observable
@MainActor
final class DebugLogFeed {
    static let pageSize: UInt32 = 500
    /// Start loading the next page while this many rows remain below the
    /// viewport, so the scroll never reaches a hard bottom.
    static let prefetchMargin = 150

    /// Loaded rows, newest first.
    private(set) var entries: [ULogEntry] = []
    /// Rows matching the filter, loaded or not.
    private(set) var total: UInt64 = 0
    /// Every distinct tag in the log, for the tag picker.
    private(set) var tags: [String] = []
    private(set) var reachedOldest = false

    var level = "All" { didSet { if level != oldValue { reload() } } }
    var tag = "All" { didSet { if tag != oldValue { reload() } } }
    /// Free text; reloads after a short pause in typing.
    var text = "" {
        didSet {
            guard text != oldValue else { return }
            textDebounce?.cancel()
            textDebounce = Task { [weak self] in
                try? await Task.sleep(nanoseconds: 250_000_000)
                guard !Task.isCancelled else { return }
                self?.reload()
            }
        }
    }

    @ObservationIgnored private var textDebounce: Task<Void, Never>?
    /// A page fetch is synchronous, but the row-appeared trigger fires in
    /// bursts; this keeps a burst from requesting the same page twice.
    @ObservationIgnored private var loadingOlder = false
    /// Rows with an id at or below this are within `prefetchMargin` of the
    /// oldest loaded row — seeing one means it's time for the next page.
    @ObservationIgnored private var prefetchThresholdID: Int64 = .min
    private let bridge: RustBridge

    init(bridge: RustBridge) {
        self.bridge = bridge
    }

    private var query: ULogQuery {
        ULogQuery(level: level == "All" ? nil : level,
                  tag: tag == "All" ? nil : tag,
                  text: text.trimmingCharacters(in: .whitespaces).nilIfEmpty)
    }

    /// Drop everything and load the first page under the current filter.
    func reload() {
        let q = query
        entries = bridge.queryLogs(q, limit: Self.pageSize)
        total = bridge.countLogs(q)
        tags = bridge.logTags()
        reachedOldest = entries.count < Int(Self.pageSize)
        loadingOlder = false
        updatePrefetchThreshold()
    }

    /// Call from each row's onAppear. Fetches the next page once the
    /// viewport nears the oldest loaded row.
    func rowAppeared(_ entry: ULogEntry) {
        guard entry.id <= prefetchThresholdID, !reachedOldest, !loadingOlder else { return }
        loadOlder()
    }

    private func loadOlder() {
        guard let oldest = entries.last?.id else { return }
        loadingOlder = true
        defer { loadingOlder = false }
        let page = bridge.queryLogs(query, beforeID: oldest, limit: Self.pageSize)
        entries.append(contentsOf: page)
        reachedOldest = page.count < Int(Self.pageSize)
        updatePrefetchThreshold()
    }

    /// Live tail: prepend rows written since the newest loaded one. With
    /// nothing loaded yet (empty log, or filter matched nothing) this is a
    /// plain reload so new matches appear.
    func poll() {
        guard let newest = entries.first?.id else { reload(); return }
        let fresh = bridge.queryLogs(query, afterID: newest)
        if !fresh.isEmpty {
            entries.insert(contentsOf: fresh, at: 0)
            total = bridge.countLogs(query)
            if tags.count != bridge.logTags().count { tags = bridge.logTags() }
        }
    }

    func clear() {
        bridge.clearLogs()
        reload()
    }

    private func updatePrefetchThreshold() {
        let index = entries.count - Self.prefetchMargin
        prefetchThresholdID = index >= 0 ? entries[index].id : .max
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
