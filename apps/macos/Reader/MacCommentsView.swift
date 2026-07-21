import SwiftUI

/// Comments for a work (detail page) or a single chapter (reader) — presented
/// as a window sheet. Cache-first load, page controls, inline replies, and a
/// top-level composer; mirrors the iOS CommentThreadView flow.
struct MacCommentsView: View {
    @Bindable var theme: AppTheme
    @Bindable var appState: AppState
    let workID: String
    /// Chapter to scope comments to; nil = whole-work comments.
    let chapterID: UInt64?
    let title: String
    let subtitle: String?
    let onClose: () -> Void

    @State private var comments: [ParsedComment] = []
    @State private var currentPage: UInt32 = 1
    @State private var totalPages: UInt32 = 1
    @State private var isLoading = false
    @State private var isLoadingAll = false
    @State private var loadAllProgress: UInt32 = 0
    @State private var loadError: String?
    @State private var commentTask = NetworkTask()

    @State private var replyingTo: UInt64?
    @State private var replyText = ""
    @State private var isSubmittingReply = false
    @State private var replyError: String?
    @State private var replySuccess = false

    @State private var newComment = ""
    @State private var isPosting = false
    @State private var postError: String?
    @State private var postSuccess = false

    private var isLoggedIn: Bool { appState.ao3Username != nil }

    /// Comments shown, counting nested replies.
    private var loadedCommentCount: Int {
        func count(_ list: [ParsedComment]) -> Int {
            list.reduce(0) { $0 + 1 + count($1.replies) }
        }
        return count(comments)
    }

    /// Append only threads not already shown — AO3's comment pages shift as
    /// new comments arrive, so consecutive pages can overlap, and duplicate
    /// IDs break SwiftUI's ForEach identity.
    private func appendUnique(_ newComments: [ParsedComment]) {
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

    var body: some View {
        let _ = theme.uiFontScale  // track app text size so fonts refresh live
        VStack(spacing: 0) {
            header
            Divider().overlay(theme.line)
            commentsList
            Divider().overlay(theme.line)
            composer
        }
        .frame(width: 620, height: 700)
        .background(theme.bg)
        .task { await loadInitial() }
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Comments")
                    .font(Font(MacFont.serif(20, weight: .semibold)))
                    .foregroundStyle(theme.ink)
                Text(subtitle.map { "\(title) · \($0)" } ?? title)
                    .font(Font(MacFont.ui(12)))
                    .foregroundStyle(theme.ink3)
                    .lineLimit(1)
            }
            Spacer()
            if !comments.isEmpty {
                // The list accumulates (Load more appends) — pages are a
                // fetch detail, not something the user sees.
                Text(currentPage < totalPages
                     ? "\(loadedCommentCount) shown · more on AO3"
                     : "\(loadedCommentCount) comment\(loadedCommentCount == 1 ? "" : "s")")
                    .font(Font(MacFont.ui(11, weight: .medium)))
                    .foregroundStyle(theme.ink3)
            }
            Button(action: onClose) {
                Image(systemName: "xmark")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(theme.ink2)
                    .frame(width: 28, height: 28)
                    .background(theme.surface2)
                    .clipShape(Circle())
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .keyboardShortcut(.cancelAction)
        }
        .padding(.init(top: 16, leading: 20, bottom: 14, trailing: 16))
    }

    // MARK: - List

    private var commentsList: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                if comments.isEmpty && isLoading {
                    VStack(spacing: 12) {
                        ProgressView().controlSize(.regular)
                        Text("Loading comments…")
                            .font(Font(MacFont.ui(13)))
                            .foregroundStyle(theme.ink3)
                        Text(commentTask.statusMessage ?? "Requests are rate-limited to be kind to the archive.")
                            .font(Font(MacFont.ui(11.5)))
                            .foregroundStyle(theme.ink3)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.top, 80)
                } else if comments.isEmpty {
                    if let loadError {
                        VStack(spacing: 10) {
                            Image(systemName: "exclamationmark.triangle")
                                .font(.system(size: 24, weight: .light))
                                .foregroundStyle(theme.ink3)
                            Text("Couldn’t load comments")
                                .font(Font(MacFont.serif(16, weight: .semibold)))
                                .foregroundStyle(theme.ink2)
                            Text(loadError)
                                .font(Font(MacFont.ui(12.5)))
                                .foregroundStyle(theme.ink3)
                                .multilineTextAlignment(.center)
                            Button("Try Again") { Task { await loadInitial() } }
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.top, 70)
                        .padding(.horizontal, 30)
                    } else {
                        Text("No comments yet.")
                            .font(Font(MacFont.ui(13)))
                            .foregroundStyle(theme.ink3)
                            .frame(maxWidth: .infinity)
                            .padding(.top, 80)
                    }
                } else {
                    ForEach(comments) { comment in
                        AnyView(commentView(comment, depth: 0))
                    }
                    footerControls
                }
            }
            .padding(.bottom, 16)
        }
        .background(theme.bg)
    }

    private func commentView(_ comment: ParsedComment, depth: Int) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .center, spacing: 8) {
                    AuthorAvatarView(theme: theme, appState: appState,
                                     username: comment.authorName,
                                     urlHint: comment.authorAvatarUrl.isEmpty ? nil : comment.authorAvatarUrl,
                                     size: 24,
                                     fetchable: !comment.authorProfileUrl.isEmpty || !comment.authorAvatarUrl.isEmpty)
                    Text(comment.authorName)
                        .font(Font(MacFont.ui(13, weight: .bold)))
                        .foregroundStyle(comment.authorProfileUrl.isEmpty ? theme.ink : theme.accent)
                    Spacer()
                    Text(comment.postedAt)
                        .font(Font(MacFont.ui(11)))
                        .foregroundStyle(theme.ink3)
                }

                let blocks = ParsedContentBlock.fromJSON(comment.contentJson)
                if !blocks.isEmpty {
                    CommentContentView(theme: theme, blocks: blocks)
                }

                if isLoggedIn {
                    Button {
                        if replyingTo == comment.id {
                            replyingTo = nil
                        } else {
                            replyingTo = comment.id
                            replyText = ""
                            replyError = nil
                            replySuccess = false
                        }
                    } label: {
                        Text("Reply")
                            .font(Font(MacFont.ui(11.5, weight: .semibold)))
                            .foregroundStyle(theme.accent)
                    }
                    .buttonStyle(.plain)

                    if replyingTo == comment.id {
                        replyField(parentId: comment.id)
                    }
                }
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
            .padding(.leading, CGFloat(depth) * 20)
            .overlay(alignment: .bottom) {
                if depth == 0 { theme.line.frame(height: 1) }
            }

            ForEach(comment.replies) { reply in
                AnyView(commentView(reply, depth: depth + 1))
            }
        }
    }

    @ViewBuilder
    private func replyField(parentId: UInt64) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            if replySuccess {
                Text("Reply posted!")
                    .font(Font(MacFont.ui(12, weight: .semibold)))
                    .foregroundStyle(theme.sage)
            } else {
                TextEditor(text: $replyText)
                    .font(Font(MacFont.ui(13)))
                    .foregroundStyle(theme.ink)
                    .scrollContentBackground(.hidden)
                    .padding(8)
                    .frame(minHeight: 60, maxHeight: 120)
                    .background(theme.surface2)
                    .clipShape(RoundedRectangle(cornerRadius: 8))

                if let replyError {
                    Text(replyError)
                        .font(Font(MacFont.ui(11.5)))
                        .foregroundStyle(Color(hex: "CE514D"))
                }

                HStack(spacing: 10) {
                    Button {
                        Task { await submitReply(parentId: parentId) }
                    } label: {
                        Text(isSubmittingReply ? "Posting…" : "Post reply")
                            .font(Font(MacFont.ui(12, weight: .bold)))
                            .foregroundStyle(theme.onAccent)
                            .padding(.horizontal, 14)
                            .frame(height: 28)
                            .background(replyDisabled ? theme.ink3 : theme.accent)
                            .clipShape(Capsule())
                    }
                    .buttonStyle(.plain)
                    .disabled(isSubmittingReply || replyDisabled)

                    Button("Cancel") { replyingTo = nil }
                        .buttonStyle(.plain)
                        .font(Font(MacFont.ui(12, weight: .semibold)))
                        .foregroundStyle(theme.ink3)
                }
            }
        }
        .padding(.top, 4)
    }

    private var replyDisabled: Bool {
        replyText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    // MARK: - Pagination footer

    @ViewBuilder
    private var footerControls: some View {
        if isLoading {
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Loading comments…")
                    .font(Font(MacFont.ui(12)))
                    .foregroundStyle(theme.ink3)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 14)
        } else if isLoadingAll {
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Loading page \(loadAllProgress) of \(totalPages)…")
                    .font(Font(MacFont.ui(12)))
                    .foregroundStyle(theme.ink3)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 14)
        } else if currentPage < totalPages {
            HStack(spacing: 10) {
                footerButton("Load more") { Task { await loadNextPage() } }
                footerButton("Load all") { Task { await loadAllPages() } }
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 14)
        } else if let loadError {
            VStack(spacing: 6) {
                Text(loadError)
                    .font(Font(MacFont.ui(12)))
                    .foregroundStyle(Color(hex: "CE514D"))
                Button("Try Again") { Task { await loadNextPage() } }
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 14)
        }
    }

    private func footerButton(_ label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(label)
                .font(Font(MacFont.ui(12, weight: .semibold)))
                .foregroundStyle(theme.ink2)
                .padding(.horizontal, 16)
                .frame(height: 30)
                .background(theme.surface)
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(theme.line, lineWidth: 1))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: - Composer

    @ViewBuilder
    private var composer: some View {
        if !isLoggedIn {
            Text("Sign in to AO3 in Settings to leave comments.")
                .font(Font(MacFont.ui(12)))
                .foregroundStyle(theme.ink3)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 14)
                .background(theme.surface)
        } else if postSuccess {
            HStack(spacing: 8) {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(theme.sage)
                Text("Comment posted!")
                    .font(Font(MacFont.ui(13, weight: .semibold)))
                    .foregroundStyle(theme.sage)
                Button("Write another") {
                    postSuccess = false
                }
                .buttonStyle(.plain)
                .font(Font(MacFont.ui(12, weight: .semibold)))
                .foregroundStyle(theme.accent)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 16)
            .background(theme.surface)
        } else {
            VStack(alignment: .leading, spacing: 8) {
                TextEditor(text: $newComment)
                    .font(Font(MacFont.ui(13)))
                    .foregroundStyle(theme.ink)
                    .scrollContentBackground(.hidden)
                    .padding(8)
                    .frame(height: 72)
                    .background(theme.surface2)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                    .overlay(alignment: .topLeading) {
                        if newComment.isEmpty {
                            Text("Leave a comment…")
                                .font(Font(MacFont.ui(13)))
                                .foregroundStyle(theme.ink3)
                                .padding(.horizontal, 12)
                                .padding(.vertical, 8)
                                .allowsHitTesting(false)
                        }
                    }

                HStack {
                    if let postError {
                        Text(postError)
                            .font(Font(MacFont.ui(11.5)))
                            .foregroundStyle(Color(hex: "CE514D"))
                            .lineLimit(2)
                    }
                    Spacer()
                    Button {
                        Task { await submitComment() }
                    } label: {
                        Text(isPosting ? "Posting…" : "Post Comment")
                            .font(Font(MacFont.ui(12.5, weight: .bold)))
                            .foregroundStyle(theme.onAccent)
                            .padding(.horizontal, 18)
                            .frame(height: 30)
                            .background(postDisabled ? theme.ink3 : theme.accent)
                            .clipShape(RoundedRectangle(cornerRadius: 8))
                    }
                    .buttonStyle(.plain)
                    .disabled(isPosting || postDisabled)
                }
            }
            .padding(.init(top: 12, leading: 20, bottom: 12, trailing: 20))
            .background(theme.surface)
        }
    }

    private var postDisabled: Bool {
        newComment.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    // MARK: - Data

    private func loadInitial() async {
        // Cached comments first — instant content while the live fetch runs.
        let cachedJson: String
        if let cid = chapterID, cid > 0 {
            cachedJson = appState.bridge.getCachedComments(workId: 0, chapterId: cid)
        } else if let wid = UInt64(workID) {
            cachedJson = appState.bridge.getCachedComments(workId: wid, chapterId: 0)
        } else {
            cachedJson = "[]"
        }
        let cached = ParsedComment.fromJSON(cachedJson)
        if !cached.isEmpty {
            comments = cached
        }
        await loadPage(1, replace: true)
    }

    private func fetchPage(_ page: UInt32) async throws -> UCommentsPage {
        guard let wid = UInt64(workID) else {
            throw Ao3Error.Network(message: "Comments aren’t available for sample works.")
        }
        if let cid = chapterID, cid > 0 {
            return try await appState.bridge.fetchChapterComments(workId: wid, chapterId: cid, page: page)
        }
        return try await appState.bridge.fetchWorkComments(workId: wid, page: page)
    }

    private func loadPage(_ page: UInt32, replace: Bool) async {
        isLoading = true
        loadError = nil
        do {
            let result = try await appState.retryOnTimeout(task: commentTask, using: appState.bridge) {
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
        } catch {
            if !commentTask.isCancelled && !"\(error)".contains("cancelled") {
                loadError = error.localizedDescription
            }
        }
        isLoading = false
    }

    private func loadNextPage() async {
        guard currentPage < totalPages else { return }
        await loadPage(currentPage + 1, replace: false)
    }

    private func loadAllPages() async {
        guard currentPage < totalPages else { return }
        isLoadingAll = true
        var nextPage = currentPage + 1
        while nextPage <= totalPages {
            loadAllProgress = nextPage
            do {
                let result = try await appState.retryOnTimeout(task: commentTask, using: appState.bridge) {
                    try await self.fetchPage(nextPage)
                }
                appendUnique(ParsedComment.fromJSON(result.commentsJson))
                currentPage = result.currentPage
                totalPages = result.totalPages
                nextPage += 1
            } catch {
                if !commentTask.isCancelled && !"\(error)".contains("cancelled") {
                    loadError = error.localizedDescription
                }
                break
            }
        }
        isLoadingAll = false
    }

    private func submitComment() async {
        guard let wid = UInt64(workID) else {
            postError = "Comments aren’t available for sample works."
            return
        }
        isPosting = true
        postError = nil
        do {
            let posted = try await appState.bridge.postComment(
                workId: wid,
                chapterId: chapterID ?? 0,
                comment: newComment.trimmingCharacters(in: .whitespacesAndNewlines))
            if posted {
                postSuccess = true
                newComment = ""
            } else {
                postError = "Failed to post comment. Please try again."
            }
        } catch {
            postError = error.localizedDescription
        }
        isPosting = false
    }

    private func submitReply(parentId: UInt64) async {
        let trimmed = replyText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        isSubmittingReply = true
        replyError = nil
        do {
            let posted = try await appState.bridge.postReply(parentCommentId: parentId, comment: trimmed)
            if posted {
                replySuccess = true
                replyText = ""
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
}
