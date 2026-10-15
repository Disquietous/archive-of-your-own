import Foundation
import Observation

/// State for one Discussion panel: the scope it shows (a chapter or the
/// whole work), the loaded comment threads, the docked composer's draft
/// and reply target, optimistic posts, and the view's sort/filter/find.
/// One model per panel host (reading pane, each work window).
@MainActor
@Observable
final class DiscussionModel {
    enum Scope: Equatable { case chapter, work }

    /// A comment the user posted that AO3 hasn't confirmed yet (or rejected).
    struct Pending: Identifiable, Equatable {
        enum State: Equatable { case posting, failed(String) }
        let id = UUID()
        let workID: UInt64
        /// The composer's chapter id (0 = whole-work).
        let chapterID: UInt64
        let parentID: UInt64?
        let body: String
        var state: State
    }

    let appState: AppState

    // MARK: Scope

    private(set) var workID: String?
    private(set) var chapterIndex = 0
    /// A reader chapter is in view (false in work-detail mode), so the
    /// chapter scope is meaningful.
    private(set) var hasReaderChapter = false
    var scope: Scope = .chapter {
        didSet { if scope != oldValue && !applyingScope { scopeChanged() } }
    }
    private var applyingScope = false
    /// The panel is on screen — loads happen only then, so a hidden panel
    /// never costs a request when the reader changes chapters.
    private(set) var isVisible = false

    // MARK: Threads

    private(set) var comments: [ParsedComment] = []
    private(set) var currentPage: UInt32 = 1
    private(set) var totalPages: UInt32 = 1
    private(set) var isLoading = false
    private(set) var isLoadingAll = false
    private(set) var loadAllProgress: UInt32 = 0
    private(set) var loadError: String?
    /// When this list was last fetched completely (every page). Set: the
    /// panel opens from the cache without asking AO3 — only the user's
    /// "Check for new comments" fetches again.
    private(set) var lastFetched: Date?
    /// Page 1 was fetched this scope, so reaching the last page means every
    /// page has been (pages load in order).
    private var fetchedFromFirstPage = false
    private(set) var expandingReplies: Set<UInt64> = []
    let commentTask = NetworkTask()
    private var loadGeneration = 0
    private var loadAllTask: Task<Void, Never>?
    /// Comment id → plain text, so find never re-decodes bodies per keystroke.
    @ObservationIgnored private var plainCache: [UInt64: String] = [:]

    var collapsed: Set<UInt64> = []
    var sortNewestFirst = false
    var authorRepliesOnly = false
    var findText = ""
    var isFinding = false
    /// Keyboard selection (↑/↓, R, ←/→, ⌘C).
    var selectedID: UInt64?
    /// Briefly set after a post lands, so the view scrolls to and tints it.
    var highlightID: UInt64?

    // MARK: Composer

    var draft = "" {
        didSet { if draft != oldValue { scheduleDraftSave() } }
    }
    private(set) var replyTargetID: UInt64?
    private(set) var pending: [Pending] = []
    /// Bumped to ask the composer to take focus (Reply, end-of-chapter CTA).
    private(set) var focusRequest = 0
    private var draftSaveTask: Task<Void, Never>?
    private var suppressDraftSave = false
    static let maxLength = 10_000

    init(appState: AppState) {
        self.appState = appState
    }

    // MARK: - Derived

    var work: Work? { workID.flatMap { appState.work(byID: $0) } }
    var isLoggedIn: Bool { appState.ao3Username != nil }

    /// The AO3 chapter id for the chapter scope; nil when chapter ids
    /// aren't known yet (single-chapter or unfetched works).
    var chapterID: UInt64? {
        guard let workID, let chapters = appState.chaptersForWork(workID),
              chapterIndex < chapters.count else { return nil }
        let id = chapters[chapterIndex].chapterId
        return id > 0 ? UInt64(id) : nil
    }

    /// Chapter scope falls back to whole-work when the chapter id is
    /// unknown — that's what AO3 shows for a one-chapter work anyway.
    var effectiveChapterID: UInt64 {
        scope == .chapter ? (chapterID ?? 0) : 0
    }

    private var numericWorkID: UInt64? { workID.flatMap(UInt64.init) }

    var scopeTitle: String {
        scope == .work || chapterID == nil ? "Whole work" : "Chapter \(chapterIndex + 1)"
    }

    var composerPlaceholder: String {
        if let target = replyTarget { return "Reply to \(target.displayName)…" }
        if scope == .chapter, chapterID != nil { return "Comment on Chapter \(chapterIndex + 1)…" }
        return "Comment on \(work?.title ?? "this work")…"
    }

    var loadedCount: Int {
        func count(_ list: [ParsedComment]) -> Int { list.reduce(0) { $0 + 1 + count($1.replies) } }
        return count(comments)
    }

    /// AO3's total for the work — only meaningful in whole-work scope.
    var workTotal: Int? {
        guard effectiveChapterID == 0, let total = work?.comments, total > 0 else { return nil }
        return total
    }

    var hasMorePages: Bool { currentPage < totalPages }

    /// Sample works have no AO3 comments to check.
    var canCheckForNew: Bool { numericWorkID != nil }

    var replyTarget: ParsedComment? {
        replyTargetID.flatMap { find($0, in: comments) }
    }

    /// Accounts credited on the work, for the Author badge.
    var creatorAccounts: Set<String> {
        guard let author = work?.author else { return [] }
        return Set(author.split(separator: ",").map {
            AppState.canonicalAuthorUsername(String($0)).lowercased()
        })
    }

    func isCreator(_ comment: ParsedComment) -> Bool {
        !comment.isGuest && creatorAccounts.contains(comment.authorId.lowercased())
    }

    /// Threads as shown: filtered, then sorted by the root comment's id
    /// (AO3 ids are sequential, so id order is posting order).
    var visibleThreads: [ParsedComment] {
        var list = comments
        if authorRepliesOnly {
            list = list.filter { containsCreator($0) }
        }
        let query = findText.trimmingCharacters(in: .whitespaces)
        if isFinding, !query.isEmpty {
            list = list.filter { matches($0, query) }
        }
        return list.sorted { sortNewestFirst ? $0.id > $1.id : $0.id < $1.id }
    }

    private func containsCreator(_ c: ParsedComment) -> Bool {
        isCreator(c) || c.replies.contains { containsCreator($0) }
    }

    func plainText(_ c: ParsedComment) -> String {
        if let cached = plainCache[c.id] { return cached }
        let text = DiscussionText.plain(c)
        plainCache[c.id] = text
        return text
    }

    func matches(_ c: ParsedComment, _ query: String) -> Bool {
        plainText(c).localizedCaseInsensitiveContains(query)
            || c.displayName.localizedCaseInsensitiveContains(query)
            || c.replies.contains { matches($0, query) }
    }

    /// This composer's unconfirmed posts under `parentID` (nil = top level).
    /// Posts from other scopes stay in `pending` until they settle.
    func pending(under parentID: UInt64?) -> [Pending] {
        let wid = numericWorkID ?? 0, cid = effectiveChapterID
        return pending.filter { $0.workID == wid && $0.chapterID == cid && $0.parentID == parentID }
    }

    // MARK: - Host-facing

    /// The reader moved (or the panel was attached to a work). In chapter
    /// scope a new chapter swaps the list and the composer's draft.
    func follow(workID: String?, chapterIndex: Int) {
        let workChanged = workID != self.workID
        let chapterChanged = chapterIndex != self.chapterIndex
        guard workChanged || chapterChanged else { return }
        flushDraft()
        self.workID = workID
        self.chapterIndex = chapterIndex
        hasReaderChapter = true
        if workChanged || scope == .chapter {
            resetForNewScope()
        }
    }

    /// Detail mode has no chapter: show the work's comments.
    func showWholeWork(workID: String?) {
        hasReaderChapter = false
        guard workID != self.workID || scope != .work else { return }
        flushDraft()
        self.workID = workID
        applyingScope = true
        scope = .work
        applyingScope = false
        resetForNewScope()
    }

    /// Entering the reader: chapter scope on this chapter.
    func showChapter(workID: String?, chapterIndex: Int) {
        hasReaderChapter = true
        guard workID != self.workID || chapterIndex != self.chapterIndex || scope != .chapter else { return }
        flushDraft()
        self.workID = workID
        self.chapterIndex = chapterIndex
        applyingScope = true
        scope = .chapter
        applyingScope = false
        resetForNewScope()
    }

    func setVisible(_ visible: Bool) {
        guard visible != isVisible else { return }
        isVisible = visible
        if visible {
            if comments.isEmpty && !isLoading { startInitialLoad() }
        } else {
            flushDraft()
        }
    }

    func requestComposerFocus() { focusRequest += 1 }

    private func scopeChanged() {
        flushDraft()
        resetForNewScope()
    }

    private func resetForNewScope() {
        loadGeneration += 1
        loadAllTask?.cancel()
        commentTask.cancel()
        comments = []
        currentPage = 1
        totalPages = 1
        loadError = nil
        lastFetched = nil
        fetchedFromFirstPage = false
        isLoading = false
        isLoadingAll = false
        collapsed = []
        expandingReplies = []
        plainCache = [:]
        restoreDraft()
        if isVisible { startInitialLoad() }
    }

    /// Show the loading state now, not after the task gets scheduled.
    func startInitialLoad() {
        isLoading = numericWorkID != nil
        Task { await loadInitial() }
    }

    // MARK: - Loading

    func loadInitial() async {
        guard let wid = numericWorkID else {
            comments = []
            loadError = "Comments aren’t available for sample works."
            return
        }
        let cid = effectiveChapterID
        let generation = loadGeneration
        isLoading = true
        loadError = nil
        // The DB read and JSON decode run off the main thread: the storage
        // lock can be held by in-flight requests.
        if let app = appState.bridge.coreApp {
            let (cached, stamp) = await Task.detached(priority: .userInitiated) {
                (ParsedComment.fromJSON((try? app.getCachedComments(workId: wid, chapterId: cid)) ?? "[]"),
                 (try? app.commentsFetchedAt(workId: wid, chapterId: cid)) ?? nil)
            }.value
            guard generation == loadGeneration else { return }
            if !cached.isEmpty && comments.isEmpty { comments = cached }
            // Fetched completely before: comments aren't posted in bulk, so
            // the cache stands until the user checks again.
            if let stamp {
                lastFetched = Date(timeIntervalSince1970: TimeInterval(stamp))
                isLoading = false
                return
            }
        }
        await loadPage(1, replace: true)
    }

    private func fetchPage(_ page: UInt32, workID wid: UInt64, chapterID cid: UInt64) async throws -> UCommentsPage {
        if cid > 0 {
            return try await appState.bridge.fetchChapterComments(workId: wid, chapterId: cid, page: page)
        }
        return try await appState.bridge.fetchWorkComments(workId: wid, page: page)
    }

    func loadPage(_ page: UInt32, replace: Bool) async {
        guard let wid = numericWorkID else { return }
        let cid = effectiveChapterID
        let generation = loadGeneration
        commentTask.reset()
        isLoading = true
        loadError = nil
        do {
            let result = try await appState.retryOnTimeout(task: commentTask, using: appState.bridge) {
                try await self.fetchPage(page, workID: wid, chapterID: cid)
            }
            let json = result.commentsJson
            let fresh = await Task.detached(priority: .userInitiated) { ParsedComment.fromJSON(json) }.value
            guard generation == loadGeneration else { return }
            // Cached threads AO3 no longer lists on this page may sit on
            // later pages; merge rather than drop them.
            merge(fresh, replacingOrder: replace)
            currentPage = max(result.currentPage, page)
            totalPages = result.totalPages
            if page == 1 { fetchedFromFirstPage = true }
            if fetchedFromFirstPage, currentPage >= totalPages { markFetched(workID: wid, chapterID: cid) }
        } catch {
            guard generation == loadGeneration else { return }
            if !commentTask.isCancelled && !error.isCancellation {
                loadError = error.localizedDescription
            }
        }
        if generation == loadGeneration { isLoading = false }
    }

    func loadNextPage() {
        guard hasMorePages, !isLoading else { return }
        Task { await loadPage(currentPage + 1, replace: false) }
    }

    /// Fold fetched threads in: a thread already shown is replaced (it may
    /// carry new replies); new threads are added. AO3's pages shift as
    /// comments arrive, so consecutive pages can overlap.
    private func merge(_ fresh: [ParsedComment], replacingOrder: Bool) {
        var byID = Dictionary(comments.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        for thread in fresh { byID[thread.id] = thread }
        if replacingOrder {
            let freshIDs = Set(fresh.map(\.id))
            comments = fresh + comments.filter { !freshIDs.contains($0.id) }
        } else {
            let existing = Set(comments.map(\.id))
            comments = comments.map { byID[$0.id] ?? $0 } + fresh.filter { !existing.contains($0.id) }
        }
    }

    /// "Load N more replies" — the thread page of `commentID`.
    func loadMoreReplies(_ commentID: UInt64) {
        guard !expandingReplies.contains(commentID) else { return }
        expandingReplies.insert(commentID)
        let generation = loadGeneration
        Task {
            defer { if generation == loadGeneration { expandingReplies.remove(commentID) } }
            do {
                guard let full = try await appState.bridge.fetchCommentReplies(commentId: commentID),
                      generation == loadGeneration else { return }
                comments = Self.replacing(commentID, with: full, in: comments)
            } catch {
                if generation == loadGeneration { loadError = error.localizedDescription }
            }
        }
    }

    // MARK: - Composer

    func reply(to comment: ParsedComment) {
        replyTargetID = comment.id
        scheduleDraftSave()
        requestComposerFocus()
    }

    func clearReplyTarget() {
        replyTargetID = nil
        scheduleDraftSave()
    }

    var trimmedDraft: String { draft.trimmingCharacters(in: .whitespacesAndNewlines) }
    var canPost: Bool { isLoggedIn && !trimmedDraft.isEmpty && draft.count <= Self.maxLength }

    func post() {
        guard canPost, let wid = numericWorkID else { return }
        let body = trimmedDraft
        let parent = replyTargetID
        let cid = effectiveChapterID
        // The Rust draft row stays until AO3 accepts the post (Rust clears
        // it then), so a quit mid-post never loses the text.
        draftSaveTask?.cancel()
        draftSaveTask = nil
        withoutDraftSave { draft = "" }
        replyTargetID = nil
        let item = Pending(workID: wid, chapterID: cid, parentID: parent, body: body, state: .posting)
        pending.append(item)
        send(item)
    }

    func retry(_ id: UUID) {
        guard let i = pending.firstIndex(where: { $0.id == id }) else { return }
        pending[i].state = .posting
        send(pending[i])
    }

    /// Move a failed post's text back into the composer.
    func edit(_ id: UUID) {
        guard let i = pending.firstIndex(where: { $0.id == id }) else { return }
        let item = pending.remove(at: i)
        replyTargetID = item.parentID
        draft = item.body
        requestComposerFocus()
    }

    func discard(_ id: UUID) {
        pending.removeAll { $0.id == id }
    }

    private func send(_ item: Pending) {
        let (wid, cid) = (item.workID, item.chapterID)
        Task {
            do {
                let result: UPostResult
                if let parent = item.parentID {
                    result = try await appState.bridge.postReply(
                        parentCommentId: parent, comment: item.body, workId: wid, chapterId: cid)
                } else {
                    result = try await appState.bridge.postComment(workId: wid, chapterId: cid, comment: item.body)
                }
                guard result.posted else {
                    markFailed(item.id, "AO3 didn’t accept the comment. Try again.")
                    return
                }
                pending.removeAll { $0.id == item.id }
                // The panel moved to another scope meanwhile: the post is
                // cached in Rust and shows when that scope is next opened.
                guard wid == numericWorkID, cid == effectiveChapterID else { return }
                if let posted = ParsedComment.single(fromJSON: result.commentJson) {
                    insert(posted, under: item.parentID)
                    flash(posted.id)
                } else {
                    // Posted, but not on the page AO3 redirected to: reload.
                    await loadPage(1, replace: true)
                }
            } catch {
                markFailed(item.id, error.localizedDescription)
            }
        }
    }

    private func markFailed(_ id: UUID, _ message: String) {
        guard let i = pending.firstIndex(where: { $0.id == id }) else { return }
        pending[i].state = .failed(message)
    }

    private func insert(_ comment: ParsedComment, under parentID: UInt64?) {
        if find(comment.id, in: comments) != nil {
            comments = Self.replacing(comment.id, with: comment, in: comments)
        } else if let parentID {
            comments = Self.appending(comment, under: parentID, in: comments)
        } else {
            comments.append(comment)
        }
    }

    private func flash(_ id: UInt64) {
        highlightID = id
        Task {
            try? await Task.sleep(for: .seconds(2.5))
            if highlightID == id { highlightID = nil }
        }
    }
}

// MARK: - Drafts (persisted in Rust, one per composer) & tree helpers

extension DiscussionModel {

    private func withoutDraftSave(_ body: () -> Void) {
        suppressDraftSave = true
        body()
        suppressDraftSave = false
    }

    private func scheduleDraftSave() {
        guard !suppressDraftSave else { return }
        draftSaveTask?.cancel()
        draftSaveTask = Task {
            try? await Task.sleep(for: .milliseconds(500))
            guard !Task.isCancelled else { return }
            saveDraftNow()
        }
    }

    private func saveDraftNow() {
        guard let wid = numericWorkID, isLoggedIn else { return }
        appState.bridge.saveCommentDraft(workId: wid, chapterId: effectiveChapterID,
                                         parentCommentId: replyTargetID ?? 0, body: draft)
    }

    /// Write any pending debounced save now (scope change, panel hidden,
    /// window closing).
    func flushDraft() {
        guard let task = draftSaveTask else { return }
        task.cancel()
        draftSaveTask = nil
        saveDraftNow()
    }

    private func restoreDraft() {
        withoutDraftSave {
            if let wid = numericWorkID, isLoggedIn,
               let saved = appState.bridge.getCommentDraft(workId: wid, chapterId: effectiveChapterID) {
                draft = saved.body
                replyTargetID = saved.parentCommentId > 0 ? saved.parentCommentId : nil
            } else {
                draft = ""
                replyTargetID = nil
            }
        }
    }

    // MARK: - Tree helpers

    func find(_ id: UInt64, in list: [ParsedComment]) -> ParsedComment? {
        for c in list {
            if c.id == id { return c }
            if let hit = find(id, in: c.replies) { return hit }
        }
        return nil
    }

    private static func replacing(_ id: UInt64, with new: ParsedComment, in list: [ParsedComment]) -> [ParsedComment] {
        list.map { c in
            if c.id == id { return new }
            var copy = c
            copy.replies = replacing(id, with: new, in: c.replies)
            return copy
        }
    }

    private static func appending(_ reply: ParsedComment, under parentID: UInt64,
                                  in list: [ParsedComment]) -> [ParsedComment] {
        list.map { c in
            var copy = c
            if c.id == parentID {
                copy.replies.append(reply)
            } else {
                copy.replies = appending(reply, under: parentID, in: c.replies)
            }
            return copy
        }
    }
}

// MARK: - Paging actions

extension DiscussionModel {
    func loadAllPages() {
        guard hasMorePages, !isLoadingAll else { return }
        let generation = loadGeneration
        isLoadingAll = true
        loadAllTask = Task {
            while generation == loadGeneration, currentPage < totalPages, !Task.isCancelled {
                loadAllProgress = currentPage + 1
                await loadPage(currentPage + 1, replace: false)
                if loadError != nil { break }
            }
            if generation == loadGeneration { isLoadingAll = false }
        }
    }

    /// "Check for new comments": fetch every page of this list again. New
    /// replies can land on any page, not just the last.
    func checkForNewComments() {
        guard numericWorkID != nil, !isLoading, !isLoadingAll else { return }
        let generation = loadGeneration
        isLoadingAll = true
        loadAllProgress = 1
        loadAllTask = Task {
            await loadPage(1, replace: true)
            while generation == loadGeneration, loadError == nil, currentPage < totalPages, !Task.isCancelled {
                loadAllProgress = currentPage + 1
                await loadPage(currentPage + 1, replace: false)
            }
            if generation == loadGeneration { isLoadingAll = false }
        }
    }

    /// Every page is in: stamp the list (the whole work stamps each of its
    /// chapters) so it isn't fetched again on open.
    private func markFetched(workID wid: UInt64, chapterID cid: UInt64) {
        lastFetched = Date()
        guard let app = appState.bridge.coreApp else { return }
        let number = UInt32(chapterIndex + 1)
        Task.detached(priority: .utility) {
            try? app.markCommentsFetched(workId: wid, chapterId: cid, chapterNumber: number)
        }
    }

    func cancelLoadAll() {
        loadAllTask?.cancel()
        commentTask.cancel()
        isLoadingAll = false
        isLoading = false
    }
}
