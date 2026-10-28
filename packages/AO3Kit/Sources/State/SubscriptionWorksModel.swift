import Foundation
import Observation

/// The Subscriptions drill-in: one subscription's (author's or series')
/// locally stored works, refreshed by an explicit full crawl of AO3.
@Observable
@MainActor
final class SubscriptionWorksModel {
    let appState: AppState

    init(appState: AppState) {
        self.appState = appState
    }

    /// When set, the drill-in is open on this subscription (display name).
    var title: String?
    var works: [Work] = []
    var isLoading = false
    var error: String?
    /// Drives the inline spinner on the tapped subscription row.
    var loadingSubscriptionID: String?
    /// Subscription identity for cache persistence.
    var subType: String = ""
    var subId: String?
    /// Progress line while a full works crawl is running ("Page 3 of 12 · 47 works…").
    var fetchStatus: String?
    /// When this drill-in's works were last fully crawled (epoch-seconds
    /// string from the DB) — drives the "refreshed 3d ago" staleness line.
    var crawledAt: String?
    /// A crawl that stopped part-way — the drill-in offers to resume it.
    var crawlStop: AppState.CrawlStop?
    /// The in-flight crawl (request-tracking standard) — its opID feeds the
    /// progress banner. Idle when nil.
    let refreshOp = TrackedOperation()
    /// The in-flight crawl's task. Each crawl gets its own instance so that
    /// cancelling one can never be undone by a later crawl's retry reset.
    private(set) var task = NetworkTask()

    var isOpen: Bool { title != nil }

    /// Show a subscription's locally stored works (author or series). Never
    /// fetches — a complete, current list comes from `refresh()`.
    /// `subscriptionID` is the parsed AO3 username (author) or series ID;
    /// `author` is only the display name and may differ from it. Returns
    /// whether the target changed (the caller drops its list filter then).
    @discardableResult
    func open(subscriptionID: String, author: String, subType: String = "author") -> Bool {
        cancelRefresh()
        let changed = subId != subscriptionID
        if changed { crawlStop = nil }
        title = author
        error = nil
        fetchStatus = nil
        isLoading = false
        loadingSubscriptionID = nil
        self.subType = subType
        subId = subscriptionID
        crawledAt = appState.bridge.getWorksCrawledAt(kind: subType, targetId: subscriptionID)

        let cached = appState.bridge.getSubscriptionWorks(subType: subType, subId: subscriptionID)
        let works = cached.map(AppState.workFromSummary)
        for work in works { appState.fetchedWorks[work.id] = work }
        self.works = works
        return changed
    }

    /// Fetch the subscription's complete works list — every page on AO3.
    /// Author subscriptions crawl /users/{name}/works; series crawl /series/{id}.
    /// `resume` picks a stopped crawl up at the page it stopped on.
    func refresh(resume: Bool = false) {
        guard let subId, !isLoading else { return }
        let subType = subType
        let stop = resume ? crawlStop : nil
        let seed = stop == nil ? [] : works
        crawlStop = nil
        var lastPage: (page: UInt32, total: UInt32)? = stop.map { ($0.nextPage - 1, $0.totalPages) }
        error = nil
        isLoading = true
        loadingSubscriptionID = subId
        let task = NetworkTask()
        self.task = task
        Task { @MainActor in
            do {
                // Request-tracking standard: one id for the whole crawl —
                // every page's requests carry it, so the progress banner
                // tracks the crawl.
                let all = try await refreshOp.run(appState.bridge) { opID in
                    let fetchPage: (UInt32) async throws -> UPagedWorks
                    if subType.lowercased().contains("series"), let seriesId = UInt64(subId) {
                        fetchPage = { [appState] in
                            try await appState.bridge.fetchSeriesWorksPaged(seriesId: seriesId, page: $0, opID: opID)
                        }
                    } else {
                        fetchPage = { [appState] in
                            try await appState.bridge.fetchAuthorWorks(username: subId, page: $0, opID: opID)
                        }
                    }
                    return try await appState.crawlAllWorks(
                        fetchPage: fetchPage, task: task,
                        startPage: stop?.nextPage ?? 1, seed: seed,
                        status: { [weak self] in self?.fetchStatus = $0 },
                        partial: { [weak self] works in
                            guard let self, self.subId == subId else { return }
                            self.works = works
                        },
                        pageDone: { lastPage = ($0, $1) })
                }
                if self.subId == subId && !task.isCancelled {
                    works = all
                    // Membership is derived from the crawled works
                    // themselves (byline / series part) — nothing to save.
                    appState.bridge.completeWorksCrawl(kind: subType, targetId: subId,
                                                       workIds: all.compactMap { UInt64($0.id) })
                    crawledAt = appState.bridge.getWorksCrawledAt(kind: subType, targetId: subId)
                    // The crawl rewrote works in the DB (author renames,
                    // updated stats) — merge them into the snapshot too.
                    appState.mergeCachedWorks(all)
                }
            } catch {
                if !task.isCancelled && !error.isCancellation, self.subId == subId {
                    self.error = error.localizedDescription
                }
            }
            if self.subId == subId {
                isLoading = false
                fetchStatus = nil
                loadingSubscriptionID = nil
                if task.isCancelled || self.error != nil, let last = lastPage, last.page < last.total {
                    crawlStop = AppState.CrawlStop(nextPage: last.page + 1, totalPages: last.total)
                }
            }
        }
    }

    /// Stop the crawl: flag it so no further page starts, and abort the
    /// page in flight — without the abort the request (and any recovery
    /// retries behind it) would run to completion first.
    func cancelRefresh() {
        task.cancel()
        if let id = refreshOp.opID {
            appState.bridge.cancelOperation(id)
        }
    }

    func close() {
        cancelRefresh()
        title = nil
        works = []
        error = nil
        fetchStatus = nil
        subId = nil
        crawlStop = nil
    }
}
