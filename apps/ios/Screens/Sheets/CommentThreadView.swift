import SwiftUI

// ParsedComment lives in AO3Kit (Models/ParsedComment.swift) — shared with macOS.

struct CommentThreadView: View {
    @Environment(AppTheme.self) var theme
    @Environment(AppState.self) var state
    @Environment(NavigationState.self) var nav
    @Environment(\.dismiss) var dismiss

    let workID: String
    let chapterID: UInt64?
    var initialComments: [ParsedComment] = []

    @State var comments: [ParsedComment] = []
    @State var currentPage: UInt32 = 1
    @State var totalPages: UInt32 = 1
    @State var isLoading = false
    @State var isLoadingAll = false
    @State var loadAllProgress: UInt32 = 0
    @State var loadError: String?
    /// When this list was last fetched completely. Set: the sheet opens
    /// from the cache without asking AO3 until the user checks again.
    @State var lastFetched: Date?
    /// Page 1 was fetched, so reaching the last page means every page was.
    @State var fetchedFromFirstPage = false
    @State var didCancel = false
    @State var commentTask = NetworkTask()
    @State var replyingTo: UInt64?
    @State var replyText = ""
    @State var isSubmittingReply = false
    @State var replyError: String?
    @State var replySuccess = false
    @State var replyDraftSaveTask: Task<Void, Never>?
    @State var avatarCache: [String: UIImage] = [:]

    var overrideLoggedIn: Bool = false

    var isLoggedIn: Bool {
        overrideLoggedIn || state.bridge.getCredentials() != nil
    }

    var body: some View {
        VStack(spacing: 0) {
            handle
            header

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    if comments.isEmpty && isLoading {
                        NetworkLoadingView(message: "Loading comments…", task: commentTask, operation: "comments") {
                            didCancel = true
                            commentTask.cancel()
                            state.bridge.cancelRequest()
                            isLoading = false
                        }
                    } else if comments.isEmpty && !isLoading {
                        if let loadError {
                            NetworkErrorView(message: loadError, onRetry: {
                                Task { await loadInitial() }
                            })
                        } else if didCancel {
                            NetworkErrorView(message: "Loading was cancelled.", onRetry: {
                                didCancel = false
                                Task { await loadInitial() }
                            })
                        } else {
                            Text("No comments yet.")
                                .font(Typography.uiBody())
                                .foregroundStyle(theme.ink3)
                                .frame(maxWidth: .infinity)
                                .padding(.top, 40)
                        }
                    } else {
                        ForEach(comments) { comment in
                            commentView(comment, depth: 0)
                        }

                        if isLoading && !comments.isEmpty {
                            NetworkLoadingView(message: "Loading comments…", task: commentTask, operation: "comments") {
                                didCancel = true
                                commentTask.cancel()
                                state.bridge.cancelRequest()
                                isLoading = false
                            }
                        }

                        if let loadError, !comments.isEmpty {
                            NetworkErrorView(message: loadError, onRetry: {
                                Task { await loadNextPage() }
                            })
                        }
                    }

                    if !comments.isEmpty && currentPage < totalPages && !isLoading {
                        pageControls
                    }
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 20)
            }

            if isLoggedIn {
                postCommentButton
            }
        }
        .background(theme.surface)
        .clipShape(RoundedRectangle(cornerRadius: Radius.sheet))
        .presentationDetents([.large])
        .presentationDragIndicator(.hidden)
        .task {
            if !initialComments.isEmpty {
                comments = initialComments
            } else {
                await loadInitial()
            }
        }
    }

    // MARK: - Header

    var handle: some View {
        RoundedRectangle(cornerRadius: 3)
            .fill(theme.line2)
            .frame(width: 36, height: 5)
            .padding(.top, 10)
            .padding(.bottom, 12)
    }

    /// Every loaded comment including nested replies — the list
    /// accumulates (Load more appends), so pages are a fetch detail.
    var loadedCommentCount: Int {
        func count(_ list: [ParsedComment]) -> Int {
            list.reduce(0) { $0 + 1 + count($1.replies) }
        }
        return count(comments)
    }

    var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text("Comments")
                .font(Typography.sheetTitle())
                .foregroundStyle(theme.ink)

            VStack(alignment: .leading, spacing: 1) {
                if !comments.isEmpty {
                    Text(currentPage < totalPages
                         ? "\(loadedCommentCount) shown · more on AO3"
                         : "\(loadedCommentCount) comment\(loadedCommentCount == 1 ? "" : "s")")
                        .font(Typography.uiSmall())
                        .foregroundStyle(theme.ink3)
                        .lineLimit(1)
                }
                if let lastFetched {
                    Text("Last fetched: \(lastFetched.formatted(date: .abbreviated, time: .shortened))")
                        .font(Typography.uiSmall())
                        .foregroundStyle(theme.ink3)
                        .lineLimit(1)
                }
            }

            Spacer()

            Button {
                Task { await checkForNewComments() }
            } label: {
                Image(systemName: "arrow.clockwise")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(theme.ink3)
                    .frame(width: 32, height: 32)
                    .background(theme.surface2)
                    .clipShape(Circle())
            }
            .disabled(isLoading || isLoadingAll || UInt64(workID) == nil)
            .accessibilityLabel("Check for new comments")

            Button { dismiss() } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(theme.ink3)
                    .frame(width: 32, height: 32)
                    .background(theme.surface2)
                    .clipShape(Circle())
            }
        }
        .padding(.horizontal, 20)
        .padding(.bottom, 12)
    }

    // MARK: - Data Loading

    func loadInitial() async {
        let cachedJson: String
        if let cid = chapterID, cid > 0 {
            cachedJson = state.bridge.getCachedComments(workId: 0, chapterId: cid)
        } else if let wid = UInt64(workID) {
            cachedJson = state.bridge.getCachedComments(workId: wid, chapterId: 0)
        } else {
            cachedJson = "[]"
        }
        let cached = ParsedComment.fromJSON(cachedJson)
        if !cached.isEmpty {
            comments = cached
        }
        // Fetched completely before: the cache stands until the user checks.
        if let wid = UInt64(workID), let at = state.bridge.commentsFetchedAt(workId: wid, chapterId: chapterID ?? 0) {
            lastFetched = at
            return
        }

        await loadPage(1, replace: true)
    }

    /// "Check for new comments": fetch every page again — new replies can
    /// land on any page.
    func checkForNewComments() async {
        guard !isLoading, !isLoadingAll else { return }
        await loadPage(1, replace: true)
        if loadError == nil { await loadAllPages() }
    }

    /// Stamp the list once its last page is in (pages load in order from 1).
    func markFetchedIfComplete() {
        guard fetchedFromFirstPage, currentPage >= totalPages, let wid = UInt64(workID) else { return }
        state.bridge.markCommentsFetched(workId: wid, chapterId: chapterID ?? 0, chapterNumber: 0)
        lastFetched = Date()
    }

    func fetchPage(_ page: UInt32) async throws -> UCommentsPage {
        guard let wid = UInt64(workID) else {
            throw Ao3Error.Network(message: "Invalid work ID")
        }
        if let cid = chapterID, cid > 0 {
            return try await state.bridge.fetchChapterComments(workId: wid, chapterId: cid, page: page)
        } else {
            return try await state.bridge.fetchWorkComments(workId: wid, page: page)
        }
    }

    func loadPage(_ page: UInt32, replace: Bool) async {
        isLoading = true
        loadError = nil
        didCancel = false
        commentTask.reset()
        do {
            let result = try await state.retryOnTimeout(task: commentTask, using: state.bridge) {
                try await self.fetchPage(page)
            }
            let newComments = ParsedComment.fromJSON(result.commentsJson)
            if replace {
                comments = newComments
            } else {
                appendUnique(newComments)
            }
            currentPage = result.currentPage
            totalPages = result.totalPages
            if page == 1 { fetchedFromFirstPage = true }
            markFetchedIfComplete()
        } catch {
            if !commentTask.isCancelled && !error.isCancellation {
                loadError = error.localizedDescription
            }
        }
        isLoading = false
    }

    func loadNextPage() async {
        guard currentPage < totalPages else { return }
        await loadPage(currentPage + 1, replace: false)
    }

    /// Append only threads not already shown — AO3's comment pages shift as
    /// new comments arrive, so consecutive pages can overlap, and duplicate
    /// IDs break SwiftUI's ForEach identity.
    func appendUnique(_ newComments: [ParsedComment]) {
        var seen = Set<UInt64>()
        func collect(_ list: [ParsedComment]) {
            for c in list {
                seen.insert(c.id)
                collect(c.replies)
            }
        }
        collect(comments)
        comments.append(contentsOf: newComments.filter { !seen.contains($0.id) })
    }

    func loadAllPages() async {
        guard currentPage < totalPages else { return }
        isLoadingAll = true
        var nextPage = currentPage + 1
        while nextPage <= totalPages {
            loadAllProgress = nextPage
            commentTask.reset()
            do {
                let result = try await state.retryOnTimeout(task: commentTask, using: state.bridge) {
                    try await self.fetchPage(nextPage)
                }
                appendUnique(ParsedComment.fromJSON(result.commentsJson))
                currentPage = result.currentPage
                totalPages = result.totalPages
                markFetchedIfComplete()
                nextPage += 1
            } catch {
                if !commentTask.isCancelled && !error.isCancellation {
                    loadError = error.localizedDescription
                }
                break
            }
        }
        isLoadingAll = false
    }

    func submitReply(parentId: UInt64) async {
        let trimmed = replyText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        isSubmittingReply = true
        replyError = nil
        replyDraftSaveTask?.cancel()
        do {
            let result = try await state.bridge.postReply(
                parentCommentId: parentId, comment: trimmed,
                workId: UInt64(workID) ?? 0, chapterId: chapterID ?? 0)
            if result.posted {
                replySuccess = true
                replyText = ""
                if let posted = ParsedComment.single(fromJSON: result.commentJson) {
                    comments = Self.appending(posted, under: parentId, in: comments)
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                    replyingTo = nil
                    replySuccess = false
                }
            } else {
                replyError = "Failed to post reply."
            }
        } catch {
            replyError = error.localizedDescription
        }
        isSubmittingReply = false
    }

    static func appending(_ reply: ParsedComment, under parentID: UInt64,
                          in list: [ParsedComment]) -> [ParsedComment] {
        list.map { c in
            var copy = c
            if c.id == parentID {
                if !copy.replies.contains(where: { $0.id == reply.id }) { copy.replies.append(reply) }
            } else {
                copy.replies = appending(reply, under: parentID, in: c.replies)
            }
            return copy
        }
    }

    // MARK: - Reply draft (one per work/chapter composer, persisted in Rust)

    /// Opening a reply: restore the saved draft when it was aimed at this
    /// same comment.
    func restoreReplyDraft(for parentId: UInt64) {
        guard let wid = UInt64(workID),
              let draft = state.bridge.getCommentDraft(workId: wid, chapterId: chapterID ?? 0),
              draft.parentCommentId == parentId else { return }
        replyText = draft.body
    }

    func scheduleReplyDraftSave(parentId: UInt64) {
        replyDraftSaveTask?.cancel()
        replyDraftSaveTask = Task {
            try? await Task.sleep(for: .milliseconds(500))
            guard !Task.isCancelled, !replyText.isEmpty, let wid = UInt64(workID) else { return }
            state.bridge.saveCommentDraft(workId: wid, chapterId: chapterID ?? 0,
                                          parentCommentId: parentId, body: replyText)
        }
    }
}
