import Foundation
import Observation

/// Navigation + selection state for the three-pane reader. Pure UI state —
/// all library data, network fetching, and persistence live in the shared
/// AppState/RustBridge, exactly as on iOS.
@Observable
@MainActor
final class MacAppModel {
    typealias Section = LibrarySection
    typealias WorkSort = LibraryListModel.WorkSort
    typealias CompletionFilter = LibraryListModel.CompletionFilter
    typealias WorkListFilter = LibraryListModel.WorkListFilter
    typealias AuthorPane = AuthorProfileModel.Pane

    let appState: AppState
    let theme: AppTheme
    /// The platform-neutral models (AO3Kit) this window shell composes.
    let search: SearchModel
    /// The ScribbleHub tab's form state (the Series Finder's fields).
    let scribbleHubSearch: ScribbleHubSearchModel
    let lists: LibraryListModel
    let follows: FollowModel
    let author: AuthorProfileModel
    let subscriptionWorks: SubscriptionWorksModel
    let ops: OperationsModel

    /// The app opens on Currently Reading — the primary use case.
    var section: Section = .reading
    /// The Sources area is showing: a tab per source, each with its own
    /// sidebar of options (MacAppModel+Sources). `section` stays the
    /// content the area's panes render.
    var sourcesShown = false
    /// The selected source tab (a source id); "" until the area first opens.
    var sourceTab = ""
    /// The option each source tab last showed, so a tab reopens where it
    /// was left. Session-scoped.
    @ObservationIgnored var sourceOptionMemory: [String: Section] = [:]
    /// A Settings tab (its title, e.g. "Privacy") someone asked to open;
    /// the Settings view selects it and clears the request.
    var settingsTabRequest: String?
    var selectedWorkID: String?

    /// The reading pane's reader state. Work windows own their own
    /// sessions; this one belongs to the main window's pane.
    @ObservationIgnored let paneReader: ReaderSession
    /// Every open work window, keyed by work id — the single authority on
    /// "is this work open somewhere other than the pane".
    @ObservationIgnored let windows: WorkWindowRegistry

    /// The pane reader is showing a work. Setting false closes it; there
    /// is no "open" without a work — use `openReader`.
    var readerOpen: Bool {
        get { paneReader.workID != nil }
        set { if !newValue { paneReader.close() } }
    }
    var readerChapter: Int {
        get { paneReader.chapter }
        set { paneReader.chapter = newValue }
    }
    var immersive: Bool {
        get { paneReader.immersive }
        set { paneReader.immersive = newValue }
    }
    /// Reading list shown in the list pane when a collection is selected.
    var selectedReadingListID: Int64?
    /// Title line for search results driven by a tag (tag pill, fandom
    /// card). Derived from the active query so it appears with a tag
    /// drill-in and clears the moment any other query replaces it — a
    /// stored copy went stale when later searches came from the form.
    var searchDisplayTitle: String? {
        if case .tag(let tag) = search.activeQuery { return tag }
        return nil
    }

    init(appState: AppState, theme: AppTheme) {
        self.appState = appState
        self.theme = theme
        self.search = SearchModel()
        self.scribbleHubSearch = ScribbleHubSearchModel()
        self.lists = LibraryListModel(appState: appState)
        self.follows = FollowModel(appState: appState)
        self.author = AuthorProfileModel(appState: appState)
        self.subscriptionWorks = SubscriptionWorksModel(appState: appState)
        self.ops = OperationsModel(appState: appState, search: search, author: author,
                                   subscriptionWorks: subscriptionWorks)
        self.paneReader = ReaderSession(appState: appState, theme: theme, layout: .pane)
        self.windows = WorkWindowRegistry(theme: theme, appState: appState)
        paneReader.host = self
        windows.model = self
        // A new query throws away the previous results, so the filter that
        // targeted them goes too — the same rule every other list follows.
        search.onNewQuery = { [weak self] in
            guard let self else { return }
            lists.listEmptied(.search)
            if !lists.retainListFilters {
                search.bookmarkListFilter = SearchModel.BookmarkListFilter()
            }
        }
    }

    var selectedWork: Work? {
        selectedWorkID.flatMap { appState.work(byID: $0) }
    }

    /// Everything the app is fetching right now, for the status bar.
    var inFlightOperations: [String] { ops.inFlightOperations }

    var hideExplicit: Bool {
        get { appState.hideExplicit }
        set { appState.hideExplicit = newValue }
    }

    // MARK: - Persisted prefs

    /// Load prefs + follows from the Rust core. Called after the encrypted
    /// DB unlocks, alongside AppState.loadPersistedState().
    func loadPersistedPrefs() {
        lists.loadPersistedPrefs()
        follows.load()
    }

    /// The list filter rule (see LibraryListModel.listEmptied).
    func listEmptied(_ sections: Section...) {
        guard !lists.retainListFilters else { return }
        for section in sections { lists.workListFilters[section] = nil }
    }

    // MARK: - Intents

    // MARK: - Per-section pane memory (session-scoped, never persisted)

    /// What the reading pane was showing for a section — restored when the
    /// user returns to it. Held in memory only, by design: gone on relaunch.
    private struct PaneSnapshot {
        var selectedWorkID: String?
        var readerOpen = false
        var readerChapter = 0
        var selectedReadingListID: Int64?
    }

    private var paneSnapshots: [Section: PaneSnapshot] = [:]

    private func snapshotPane(for s: Section) {
        paneSnapshots[s] = PaneSnapshot(
            selectedWorkID: selectedWorkID,
            readerOpen: readerOpen,
            readerChapter: readerChapter,
            selectedReadingListID: selectedReadingListID)
    }

    private func restorePane(for s: Section) {
        let snap = paneSnapshots[s] ?? PaneSnapshot()
        immersive = false
        selectedReadingListID = snap.selectedReadingListID
        selectedWorkID = snap.selectedWorkID
        readerChapter = snap.readerChapter
        if snap.readerOpen, let id = snap.selectedWorkID, !windows.isOpen(id) {
            // Reopening the reader lands where it was — stash the saved
            // position exactly like openReader does. A work that moved to
            // its own window while this section was away stays there.
            paneReader.restore(id, chapter: snap.readerChapter)
        } else {
            readerOpen = false
        }
    }

    func goSection(_ s: Section) {
        // A section that belongs to a source opens inside the Sources
        // area, whoever asked for it; any other leaves the area.
        noteSourcesArea(for: s)
        guard s != section else { return }
        // Remember what this section's pane was showing; restore the target's.
        // Drill-in state (author/subscription works lists, inbox selection)
        // is deliberately left alive — it only renders in its own section,
        // and in-flight crawls keep their bookkeeping.
        snapshotPane(for: section)
        // Leaving the work (even to another section) drops the return point.
        readerReturnPoint = nil
        section = s
        restorePane(for: s)
        switch s {
        case .search:
            // Choosing Search in the sidebar makes it the home context —
            // the results back arrow goes to the form, not a past trigger.
            searchReturnSection = nil
            Task { await search.loadFormIfNeeded(appState) }
        case .subscriptions:
            Task { await appState.loadSubscriptions() }
        case .whatsNew:
            lists.resetWhatsNewPins()
            appState.loadNotifications()
        case .inbox:
            appState.loadCachedInbox()
            Task { await appState.checkInbox() }
        default:
            break
        }
    }

    /// Open a reading list's works in the reading pane (the Reading Lists
    /// section's drill-in, mirroring the Subscriptions → works flow).
    func goReadingList(_ listID: Int64) {
        goSection(.readingLists)
        if selectedReadingListID != listID { listEmptied(.readingLists) }
        selectedReadingListID = listID
        selectedWorkID = nil
        readerOpen = false
    }

    /// Close the drill-in: back to "select a list".
    func closeReadingList() {
        listEmptied(.readingLists)
        selectedReadingListID = nil
        selectedWorkID = nil
        readerOpen = false
    }

    var filteredReadingListWorks: [Work] {
        works(for: .readingLists)
    }

    /// Route a link (⌘L, a URL dropped on a window, or a link clicked in
    /// content) to the matching screen. The core classifies it for every
    /// source and names the destination by library id. Returns nil when it
    /// opened, else the message to show — no source knows the link, or
    /// it's a page the app has no view for.
    @discardableResult
    func openLink(_ raw: String) -> String? {
        guard let destination = appState.bridge.openLink(raw) else {
            return "The link couldn’t be opened — the library isn’t available."
        }
        switch destination {
        case .unknown(let message), .unsupported(let message):
            return message
        case .work(let workID, _):
            // The mac reader has no entire-work mode; the detail is the
            // closest landing.
            openLinkedWork(String(workID))
        case .chapter(let workID, let chapterID):
            let id = String(workID)
            Task { @MainActor in
                if let chapter = await appState.resolveChapterLink(workID: id, chapterID: chapterID) {
                    openReader(id, chapter: chapter)
                } else {
                    openLinkedWork(id)
                }
            }
        case .user(let userID, _, let pane):
            switch pane {
            case .profile: openAuthorProfile(userID: userID)
            case .works: showAuthorPane(userID: userID, .works)
            case .bookmarks: showAuthorPane(userID: userID, .bookmarks)
            case .collections: showAuthorPane(userID: userID, .collections)
            }
        case .series(let seriesID, let name):
            openSeries(id: String(seriesID), name: name)
        case .collection(let name):
            openSearch { [self] in
                search.scope = .collections
                search.startCollectionQuery(name, appState: appState)
            }
        case .tag(let name):
            // A tag listing link: the site's results, whatever the source
            // toggle says (the Fandoms "Search AO3" rule).
            openSearch { [self] in
                search.startAO3TagListing(name, appState: appState)
            }
        }
        return nil
    }

    /// Show a linked work's detail. A work the library knows only as a
    /// stub is fetched first (the fetch saves it and its chapter list), and
    /// a failed fetch is reported the way an unopenable link is.
    private func openLinkedWork(_ id: String) {
        if appState.work(byID: id) != nil {
            selectWork(id)
            return
        }
        Task { @MainActor in
            if let workID = UInt64(id), appState.bridge.getCachedWork(workID) == nil {
                do {
                    _ = try await appState.bridge.fetchWork(workID)
                } catch {
                    if !error.isCancellation {
                        AppDelegate.presentLinkFailure(RustBridge.errorMessage(error))
                    }
                    return
                }
            }
            openWorkByID(id)
        }
    }

    /// Show a work's detail page, fetching its metadata first when it isn't
    /// known locally (e.g. opened from a pasted URL).
    /// Open a series' locally stored works (the subscriptions drill-in)
    /// — a series bookmark row's click target.
    func openSeries(id: String, name: String) {
        goSection(.subscriptions)
        openSubscriptionAuthorWorks(subscriptionID: id,
                                    author: name.isEmpty ? "Series \(id)" : name,
                                    subType: "series")
    }

    func openWorkByID(_ id: String) {
        if appState.work(byID: id) != nil {
            selectWork(id)
            return
        }
        Task { @MainActor in
            await appState.fetchWorkMetadata(id)
            if appState.work(byID: id) != nil {
                selectWork(id)
            }
        }
    }

    /// Open what a subscription row points at. A subscription names its
    /// target by the site's id (username, work number, series number);
    /// works and series resolve to library ids through the target's link.
    func openSubscriptionTarget(_ sub: USubscription) {
        let type = sub.subType.lowercased()
        if type.contains("series") {
            guard let id = appState.seriesRowID(forLink: sub.url, name: sub.name) else { return }
            openSeries(id: id, name: sub.name)
        } else if type.contains("author") || type.contains("user") {
            openSubscriptionAuthorWorks(subscriptionID: sub.id, author: sub.name, subType: "author")
        } else if type.contains("work") {
            guard let id = appState.workRowID(forLink: sub.url) else { return }
            openWorkByID(id)
        }
    }

    /// Jump from the end of a work straight into the next work of its
    /// series, fetching metadata first when it isn't known locally.
    /// `id` is the next work's library id.
    func openNextWorkInSeries(_ id: String) {
        Task { @MainActor in
            if appState.work(byID: id) == nil {
                await appState.fetchWorkMetadata(id)
            }
            // Restricted/deleted next work: stay where we are.
            guard appState.work(byID: id) != nil else { return }
            // Already reading it in a window: surface that window and
            // leave the pane on the finished work.
            if windows.show(id) { return }
            selectWork(id)
            openReader(id, chapter: 0)
        }
    }

    /// Escape: close the innermost open context.
    /// Returns false when there was nothing left to close.
    @discardableResult
    func escapeInnermost() -> Bool {
        if immersive {
            exitImmersive()
            return true
        }
        if readerOpen {
            closeReader()
            return true
        }
        if selectedWorkID != nil {
            clearSelection()
            return true
        }
        if section == .subscriptions && subscriptionWorks.isOpen {
            closeSubscriptionWorks()
            return true
        }
        if section == .authors && author.isOpen {
            closeAuthorWorks()
            return true
        }
        if section == .fandoms && fandomWorksTag != nil {
            closeFandomWorks()
            return true
        }
        return false
    }

    func selectWork(_ id: String) {
        if selectedWorkID != id { selectedWorkID = id }
        if readerOpen { readerOpen = false }
        readerReturnPoint = nil
        // Opening the detail view counts as "seen" for the What's New badge.
        appState.markDetailViewed(id)
        appState.markNewWorkSeen(id)
        // Fill in full metadata (tags, summary, chapter titles) if the row
        // came from a listing with partial data.
        Task { await appState.fetchWorkMetadata(id) }
    }

    /// Start/Continue Reading. A work is open in at most one place — if a
    /// window already has it, that window comes forward instead and the
    /// pane is left as it is (the detail view may still show it; only a
    /// reader tracks progress). With the Open in New Window setting on, a
    /// fresh open goes to a window; chapter changes inside a work the pane
    /// is already reading stay in the pane.
    func openReader(_ id: String, chapter: Int, at pos: Int? = nil) {
        if windows.show(id) { return }
        if theme.openWorksInWindow, !(readerOpen && selectedWorkID == id) {
            windows.open(id, chapter: chapter, at: pos)
            return
        }
        openReaderInPane(id, chapter: chapter, at: pos)
    }

    /// Open `id` in the pane reader regardless of the window setting — the
    /// path a window uses to hand its work back to the main window.
    func openReaderInPane(_ id: String, chapter: Int, at pos: Int? = nil) {
        if windows.show(id) { return }
        selectedWorkID = id
        paneReader.open(id, chapter: chapter, at: pos)
    }

    /// Saved position (character offset) for the chapter being opened;
    /// consumed by the reader on its first successful render.
    var readerResumePos: Int {
        get { paneReader.resumePos }
        set { paneReader.resumePos = newValue }
    }

    typealias ReaderReturnPoint = ReaderSession.ReturnPoint
    var readerReturnPoint: ReaderReturnPoint? {
        get { paneReader.returnPoint }
        set { paneReader.returnPoint = newValue }
    }

    func stashReturnPoint(chapter: Int, pos: Int) {
        paneReader.stashReturnPoint(chapter: chapter, pos: pos)
    }

    func returnToPreviousPosition() {
        paneReader.returnToPreviousPosition()
    }

    func closeReader() {
        paneReader.close()
    }

    /// The library file was replaced underneath the core: every open
    /// reader (pane and windows) moves to the position the new library
    /// holds for its work instead of persisting the old one over it.
    func reanchorOpenReaders() {
        paneReader.reanchorFromStorage()
        windows.reanchorAll()
    }

    /// Leave immersive reading. When immersive is the user's default reading
    /// view there is no single-pane reader to fall back to, so backing out
    /// closes the reader and returns to the work details view.
    func exitImmersive() {
        if theme.fullscreenReading {
            closeReader()
        } else {
            immersive = false
        }
    }

    /// Remove one work from Currently Reading; if it's showing in the reading
    /// pane, unload it there too.
    func removeFromCurrentlyReading(_ id: String) {
        appState.resetProgress(id)
        if selectedWorkID == id {
            clearSelection()
        }
    }

    /// Clear the whole Currently Reading list (all saved positions, including
    /// orphaned records), unloading the reading pane if it showed one of them.
    func removeAllCurrentlyReading() {
        let ids = appState.removeAllCurrentlyReading()
        if let selected = selectedWorkID, ids.contains(selected) {
            clearSelection()
        }
    }

    func clearSelection() {
        selectedWorkID = nil
        readerOpen = false
        immersive = false
    }

    /// The reading pane header's Close: unload the shown work and return
    /// the pane to its empty state. The only way back out when the list
    /// that selected the work has since emptied.
    func closeSelectedWork() {
        clearSelection()
    }

    /// Where a search was triggered from, when that wasn't the Search
    /// section itself — the results back arrow returns here instead of
    /// the criteria form. Cleared once used, or when the user navigates
    /// to Search themselves.
    private(set) var searchReturnSection: Section?

    /// The search results back arrow: one level toward where the search
    /// came from — the collections hit list behind a drill-in, the
    /// originating section for searches triggered outside the Search
    /// section (a work detail's tag pill), the criteria form otherwise.
    @MainActor
    func searchBack() {
        if !search.canReturnToCollectionHits, let target = searchReturnSection {
            searchReturnSection = nil
            search.showingResults = false
            goSection(target)
            return
        }
        search.returnToForm()
    }

    /// The one process for driving the Search section from anywhere in
    /// the app: switch to the section (snapshotting the pane it replaces,
    /// and remembering it as the back arrow's return target), drop the
    /// pane's prior context (a new search replaces it by design), then
    /// run the caller's query synchronously — results render on the very
    /// next pass, so the criteria form never appears in between.
    @MainActor
    private func openSearch(andRun run: @MainActor () -> Void) {
        if section != .search {
            snapshotPane(for: section)
            searchReturnSection = section
            section = .search
            sourcesShown = false
        } else {
            searchReturnSection = nil
        }
        readerOpen = false
        selectedWorkID = nil
        immersive = false
        run()
    }

    /// A tag pill or fandom card: live tag-scoped results shown in Search.
    @MainActor
    func searchTag(_ tag: String) {
        openSearch { [self] in
            search.startTagQuery(tag, appState: appState)
        }
    }

    /// From a work detail reached via search results: back to the results list.
    func backToResults() {
        selectedWorkID = nil
        readerOpen = false
        immersive = false
    }

    // MARK: - Fandom drill-in

    /// Fandom drill-in: a followed fandom's works shown in the reading pane
    /// without ever leaving the Fandoms section. Local-first — opening shows
    /// the library's works for that fandom; AO3 is only searched on the
    /// explicit toolbar action.
    var fandomWorksTag: String?
    var fandomSearchActive = false

    func openFandomWorks(_ tag: String) {
        if fandomWorksTag != tag { listEmptied(.fandoms) }
        fandomWorksTag = tag
        fandomSearchActive = false
        readerOpen = false
        selectedWorkID = nil
        immersive = false
    }

    /// The explicit — and only — network trigger for the fandom drill-in:
    /// swap the pane to AO3's paged tag results.
    func searchFandomOnAO3() {
        guard let tag = fandomWorksTag else { return }
        fandomSearchActive = true
        selectedWorkID = nil
        Task { @MainActor in
            search.startAO3TagListing(tag, appState: appState)
        }
    }

    /// Back from AO3 results to the library view of the open fandom.
    func showFandomLibraryWorks() {
        fandomSearchActive = false
        selectedWorkID = nil
    }

    func closeFandomWorks() {
        listEmptied(.fandoms)
        fandomWorksTag = nil
        fandomSearchActive = false
        selectedWorkID = nil
    }

    /// Library works for the open fandom — matched against every fandom tag
    /// on the work (crossovers count), the same tally the Fandoms list rows
    /// show.
    var fandomLibraryWorks: [Work] {
        // List filter only — the fandom drill-in never applied the section
        // completion/rating filters or a sort.
        lists.listFiltered(fandomLibraryWorksRaw, section: .fandoms)
    }

    var fandomLibraryWorksRaw: [Work] {
        fandomWorksTag.map { appState.libraryWorks(inFandom: $0) } ?? []
    }

    // MARK: - Author profile (two-pane author view)

    /// Where the author view was entered from when it wasn't the Authors
    /// list (a work detail's byline, search results, the Following
    /// drill-in) — the profile's back button returns there.
    var authorDetailReturnSection: Section?
}

// MARK: - Pane reader host

extension MacAppModel: ReaderSessionHost {
    func readerSessionDidClose(_ session: ReaderSession) {
        closeReader()
    }

    func readerSession(_ session: ReaderSession, openNextWork id: String) {
        openNextWorkInSeries(id)
    }

    func readerSession(_ session: ReaderSession, openLink url: URL) {
        openContentLink(url)
    }

    /// A link clicked in content (chapter text, a bio, a comment): a page
    /// the app has a view for opens there, anything else leaves the app.
    /// Returns whether it opened in the app.
    @discardableResult
    func openContentLink(_ url: URL) -> Bool {
        if openLink(url.absoluteString) == nil { return true }
        ExternalLinkOpener.open(url, bridge: appState.bridge)
        return false
    }
}
