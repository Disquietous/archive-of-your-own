import Foundation
import Observation

/// An author's profile and their three lists — works, public bookmarks,
/// collections. Local-first: opening shows what the library has cached;
/// AO3 is only touched by the explicit refresh actions, each of which
/// walks every page.
@Observable
@MainActor
final class AuthorProfileModel {
    let appState: AppState

    init(appState: AppState) {
        self.appState = appState
    }

    enum Pane { case works, bookmarks, collections }

    /// The open author (AO3 username); nil when no profile is showing.
    var username: String?
    var works: [Work] = []
    /// Last completed full crawl for this author (epoch-seconds string).
    var worksCrawledAt: String?
    var isLoadingWorks = false
    var worksError: String?
    /// Progress line while a full works crawl is running.
    var worksFetchStatus: String?
    /// The in-flight works crawl (request-tracking standard) — its opID
    /// feeds the progress banner. Idle when nil.
    let worksRefreshOp = TrackedOperation()
    /// Same, for the bookmarks pane's page walk.
    let bookmarksRefreshOp = TrackedOperation()
    /// The in-flight crawl's task. Each crawl gets its own instance so that
    /// cancelling one can never be undone by a later crawl's retry reset.
    private(set) var worksTask = NetworkTask()

    /// Which of the author's lists is showing beside their profile.
    var pane: Pane = .works

    /// Until the user picks a list by hand, the view lands on the author's
    /// first non-empty one once the profile's counts arrive.
    private var paneAutoSelect = false

    /// The author's public bookmarks (work and series hits), accumulated
    /// page by page.
    var bookmarks: [UBookmarkHit] = []
    var bookmarksPage: UInt32 = 0
    var bookmarksHasNext = false
    var isLoadingBookmarks = false
    var bookmarksError: String?

    /// The author's collections, accumulated page by page.
    var collections: [UCollection] = []
    var collectionsPage: UInt32 = 0
    var collectionsHasNext = false
    var isLoadingCollections = false
    var collectionsError: String?

    var isOpen: Bool { username != nil }

    /// Open the profile on an author. Works never fetch here — a complete,
    /// current list comes from `refreshWorks()`. Returns whether the author
    /// changed (the caller drops its list filters then).
    @discardableResult
    func open(_ username: String) -> Bool {
        worksTask.cancel()
        let changed = self.username != username
        if changed {
            resetPanes()
            paneAutoSelect = true
        }
        self.username = username
        worksError = nil
        worksFetchStatus = nil
        isLoadingWorks = false

        worksCrawledAt = appState.bridge.getWorksCrawledAt(subType: "author", subId: username)
        let cached = appState.bridge.getWorksByAuthor(username: username)
        let works = cached.map(AppState.workFromSummary)
        for work in works { appState.fetchedWorks[work.id] = work }
        self.works = works

        // Bookmarks and collections hydrate lazily when their pane is
        // picked (loadPaneContent) — loading them here would query the DB
        // for panes that may never be shown.
        loadPaneContent(pane, username: username)

        // The profile feeds the author card and, once its counts are known,
        // picks which list opens first.
        Task { @MainActor in
            await appState.loadUserProfile(username)
            applyDefaultPane(username)
        }
        return changed
    }

    /// Fetch the author's complete works list — every page on AO3.
    func refreshWorks() {
        guard let username, !isLoadingWorks else { return }
        worksError = nil
        isLoadingWorks = true
        let task = NetworkTask()
        worksTask = task
        Task { @MainActor in
            do {
                // Request-tracking standard: one id for the whole crawl —
                // every page's requests carry it, so the progress banner
                // tracks the crawl.
                let all = try await worksRefreshOp.run(appState.bridge) { opID in
                    try await appState.crawlAllWorks(
                        fetchPage: { [appState] in
                            try await appState.bridge.fetchAuthorWorks(username: username, page: $0, opID: opID)
                        },
                        task: task,
                        status: { [weak self] in self?.worksFetchStatus = $0 },
                        partial: { [weak self] works in
                            guard let self, self.username == username else { return }
                            self.works = works
                        })
                }
                if self.username == username && !task.isCancelled {
                    appState.bridge.setWorksCrawledNow(subType: "author", subId: username)
                    worksCrawledAt = appState.bridge.getWorksCrawledAt(subType: "author", subId: username)
                    appState.mergeCachedWorks(all)
                    // Show the cache union, not just the crawl result: works
                    // that disappeared from AO3 stay on the author's list.
                    let cached = appState.bridge.getWorksByAuthor(username: username)
                    let works = cached.map(AppState.workFromSummary)
                    for work in works { appState.fetchedWorks[work.id] = work }
                    self.works = works.isEmpty ? all : works
                }
            } catch {
                if !task.isCancelled && !error.isCancellation, self.username == username {
                    worksError = error.localizedDescription
                }
            }
            if self.username == username {
                isLoadingWorks = false
                worksFetchStatus = nil
            }
        }
    }

    func cancelWorksRefresh() {
        worksTask.cancel()
    }

    func close() {
        worksTask.cancel()
        username = nil
        works = []
        worksError = nil
        worksFetchStatus = nil
        resetPanes()
    }

    // MARK: - Panes (works / bookmarks / collections)

    /// Swap to one of the author's lists. Local-first — the pane shows
    /// what's cached, and its Refresh button is the only path to AO3.
    func showPane(_ pane: Pane) {
        paneAutoSelect = false
        self.pane = pane
        if let username {
            loadPaneContent(pane, username: username)
        }
    }

    /// Local-first, like the works list: bookmarks and collections show
    /// whatever earlier fetches cached; AO3 is only touched by each
    /// pane's explicit Refresh button. Works load in `open` — they are the
    /// landing pane; the others hydrate on first selection.
    private func loadPaneContent(_ pane: Pane, username: String) {
        switch pane {
        case .works:
            break
        case .bookmarks:
            if bookmarks.isEmpty {
                let cached = appState.bridge.getLibraryUserBookmarks(username: username)
                for work in cached.compactMap(\.work).map(AppState.workFromSummary) {
                    appState.fetchedWorks[work.id] = work
                }
                bookmarks = cached
            }
        case .collections:
            if collections.isEmpty {
                collections = appState.bridge.searchLibraryCollections(username).filter { collection in
                    collection.maintainers.contains { $0.caseInsensitiveCompare(username) == .orderedSame }
                }
            }
        }
    }

    /// The default list for a freshly opened author: the first of works /
    /// bookmarks / collections whose profile count is non-zero. No-op once
    /// the user has picked a list themselves.
    private func applyDefaultPane(_ username: String) {
        guard paneAutoSelect, self.username == username,
              let profile = appState.userProfile(username) else { return }
        paneAutoSelect = false
        guard profile.worksCount == 0 else { return } // already on .works
        if profile.bookmarksCount > 0 {
            pane = .bookmarks
        } else if profile.collectionsCount > 0 {
            pane = .collections
        }
        loadPaneContent(pane, username: username)
    }

    /// Refetch the bookmarks from AO3, starting over at page 1 and walking
    /// every page — the pane's main network trigger. Pages land in the list
    /// as they arrive; the Rust client's rate limiter paces the requests.
    func refreshBookmarks() {
        guard let username, !isLoadingBookmarks else { return }
        isLoadingBookmarks = true
        bookmarks = []
        bookmarksPage = 0
        bookmarksHasNext = false
        bookmarksError = nil
        Task { @MainActor in
            // Request-tracking standard: one id for the whole walk — every
            // page's requests carry it, so the progress banner tracks it.
            await bookmarksRefreshOp.run(appState.bridge) { opID in
                while await fetchBookmarksPage(username: username, opID: opID) == true,
                      self.username == username {}
            }
            if self.username == username { isLoadingBookmarks = false }
        }
    }

    /// Fetch the next page of the author's public bookmarks (page 1 when
    /// nothing is loaded) — resumes an interrupted refresh walk.
    func loadMoreBookmarks() {
        guard let username, !isLoadingBookmarks else { return }
        isLoadingBookmarks = true
        Task { @MainActor in
            await bookmarksRefreshOp.run(appState.bridge) { opID in
                _ = await fetchBookmarksPage(username: username, opID: opID)
            }
            if self.username == username { isLoadingBookmarks = false }
        }
    }

    /// Fetch the page after `bookmarksPage` and append its hits to the
    /// list. Returns whether AO3 reports a further page, or nil on error
    /// or when the profile has moved to a different author.
    private func fetchBookmarksPage(username: String, opID: UInt64) async -> Bool? {
        bookmarksError = nil
        let page = bookmarksPage + 1
        do {
            let result = try await appState.bridge.fetchUserBookmarksPage(username: username, page: page,
                                                                          opID: opID)
            guard self.username == username else { return nil }
            // The core cached the targets and bookmark rows; reopening the
            // author replays them from the library without touching AO3.
            for work in result.bookmarks.compactMap(\.work).map(AppState.workFromSummary) {
                appState.fetchedWorks[work.id] = work
            }
            let existing = Set(bookmarks.map(\.targetKey))
            bookmarks.append(contentsOf: result.bookmarks.filter { !existing.contains($0.targetKey) })
            bookmarksPage = page
            bookmarksHasNext = result.hasNextPage
            return result.hasNextPage
        } catch {
            if self.username == username, !error.isCancellation {
                bookmarksError = error.localizedDescription
            }
            return nil
        }
    }

    /// Refetch the collections from AO3, starting over at page 1 — the only
    /// network trigger for the pane. Fetched pages land in the collections
    /// cache, so the local-first open finds them next time.
    func refreshCollections() {
        guard !isLoadingCollections else { return }
        collections = []
        collectionsPage = 0
        collectionsHasNext = false
        collectionsError = nil
        loadMoreCollections()
    }

    /// Fetch the next page of the author's collections (page 1 when nothing
    /// is loaded).
    func loadMoreCollections() {
        guard let username, !isLoadingCollections else { return }
        isLoadingCollections = true
        collectionsError = nil
        let page = collectionsPage + 1
        Task { @MainActor in
            do {
                let result = try await appState.bridge.fetchUserCollections(username: username, page: page)
                guard self.username == username else { return }
                let existing = Set(collections.map(\.name))
                collections.append(contentsOf: result.collections.filter { !existing.contains($0.name) })
                collectionsPage = page
                collectionsHasNext = result.hasNextPage
            } catch {
                if self.username == username, !error.isCancellation {
                    collectionsError = error.localizedDescription
                }
            }
            if self.username == username { isLoadingCollections = false }
        }
    }

    private func resetPanes() {
        pane = .works
        paneAutoSelect = false
        bookmarks = []
        bookmarksPage = 0
        bookmarksHasNext = false
        isLoadingBookmarks = false
        bookmarksError = nil
        collections = []
        collectionsPage = 0
        collectionsHasNext = false
        isLoadingCollections = false
        collectionsError = nil
    }
}
