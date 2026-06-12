import SwiftUI

struct ParsedComment: Identifiable, Codable {
    let id: UInt64
    let authorId: String
    let authorName: String
    let authorProfileUrl: String
    let authorAvatarUrl: String
    let postedAt: String
    let contentJson: String
    let replies: [ParsedComment]

    enum CodingKeys: String, CodingKey {
        case id
        case authorId = "author_id"
        case authorName = "author_name"
        case authorProfileUrl = "author_profile_url"
        case authorAvatarUrl = "author_avatar_url"
        case postedAt = "posted_at"
        case contentJson = "content_json"
        case replies
    }

    static func fromJSON(_ json: String) -> [ParsedComment] {
        guard let data = json.data(using: .utf8) else { return [] }
        return (try? JSONDecoder().decode([ParsedComment].self, from: data)) ?? []
    }
}

struct CommentThreadView: View {
    @Environment(AppTheme.self) private var theme
    @Environment(AppState.self) private var state
    @Environment(NavigationState.self) private var nav
    @Environment(\.dismiss) private var dismiss

    let workID: String
    let chapterID: UInt64?

    @State private var comments: [ParsedComment] = []
    @State private var currentPage: UInt32 = 1
    @State private var totalPages: UInt32 = 1
    @State private var isLoading = false
    @State private var isLoadingAll = false
    @State private var loadAllProgress: UInt32 = 0
    @State private var loadError: String?
    @State private var didCancel = false
    @State private var commentTask = NetworkTask()
    @State private var replyingTo: UInt64?
    @State private var replyText = ""
    @State private var isSubmittingReply = false
    @State private var replyError: String?
    @State private var replySuccess = false
    @State private var avatarCache: [String: UIImage] = [:]

    private var isLoggedIn: Bool {
        state.bridge.getCredentials() != nil
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
            await loadInitial()
        }
    }

    // MARK: - Header

    private var handle: some View {
        RoundedRectangle(cornerRadius: 3)
            .fill(theme.line2)
            .frame(width: 36, height: 5)
            .padding(.top, 10)
            .padding(.bottom, 12)
    }

    private var header: some View {
        HStack {
            Text("Comments")
                .font(Typography.sheetTitle())
                .foregroundStyle(theme.ink)

            Spacer()

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

    // MARK: - Comment View

    private func commentView(_ comment: ParsedComment, depth: Int) -> AnyView {
        AnyView(
            VStack(alignment: .leading, spacing: 6) {
                // Author row with avatar
                HStack(alignment: .top, spacing: 10) {
                    avatarView(comment)

                    VStack(alignment: .leading, spacing: 2) {
                        if !comment.authorProfileUrl.isEmpty {
                            Text(comment.authorName)
                                .font(.custom("HankenGrotesk", size: 14).weight(.semibold))
                                .foregroundStyle(theme.accent)
                        } else {
                            Text(comment.authorName)
                                .font(.custom("HankenGrotesk", size: 14).weight(.semibold))
                                .foregroundStyle(theme.ink)
                        }

                        Text(comment.postedAt)
                            .font(.custom("HankenGrotesk", size: 12).weight(.medium))
                            .foregroundStyle(theme.ink3)
                    }

                    Spacer()
                }

                // Comment body
                let blocks = ParsedContentBlock.fromJSON(comment.contentJson)
                if !blocks.isEmpty {
                    ContentBlockView(blocks: blocks, compact: true)
                }

                // Reply button
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
                            .font(.custom("HankenGrotesk", size: 12).weight(.semibold))
                            .foregroundStyle(theme.accent)
                    }

                    if replyingTo == comment.id {
                        replyField(parentId: comment.id)
                    }
                }

                // Replies
                if !comment.replies.isEmpty {
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(comment.replies) { reply in
                            commentView(reply, depth: depth + 1)
                        }
                    }
                    .padding(.leading, 16)
                    .overlay(alignment: .leading) {
                        Rectangle()
                            .fill(theme.line)
                            .frame(width: 2)
                    }
                }
            }
            .padding(.vertical, 12)
            .overlay(alignment: .bottom) {
                if depth == 0 {
                    Divider().foregroundStyle(theme.line)
                }
            }
        )
    }

    // MARK: - Avatar

    @ViewBuilder
    private func avatarView(_ comment: ParsedComment) -> some View {
        let size: CGFloat = 32
        if let cached = avatarCache[comment.authorId] {
            Image(uiImage: cached)
                .resizable()
                .aspectRatio(contentMode: .fill)
                .frame(width: size, height: size)
                .clipShape(Circle())
        } else {
            Circle()
                .fill(theme.surface2)
                .frame(width: size, height: size)
                .overlay {
                    Text(String(comment.authorName.prefix(1)).uppercased())
                        .font(.custom("HankenGrotesk", size: 14).weight(.bold))
                        .foregroundStyle(theme.ink3)
                }
                .task {
                    await loadAvatar(for: comment)
                }
        }
    }

    private func loadAvatar(for comment: ParsedComment) async {
        guard !comment.authorAvatarUrl.isEmpty,
              avatarCache[comment.authorId] == nil else { return }
        do {
            let data = try await state.bridge.fetchImage(url: comment.authorAvatarUrl)
            if let image = UIImage(data: data) {
                avatarCache[comment.authorId] = image
            }
        } catch {
            // Silently fail — placeholder initial shown instead
        }
    }

    // MARK: - Reply

    @ViewBuilder
    private func replyField(parentId: UInt64) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            if replySuccess {
                Text("Reply posted!")
                    .font(Typography.uiSmall())
                    .foregroundStyle(theme.sage)
            } else {
                TextEditor(text: $replyText)
                    .font(.custom("HankenGrotesk", size: 14).weight(.medium))
                    .foregroundStyle(theme.ink)
                    .scrollContentBackground(.hidden)
                    .padding(8)
                    .frame(minHeight: 60, maxHeight: 120)
                    .background(theme.surface2)
                    .clipShape(RoundedRectangle(cornerRadius: 8))

                if let replyError {
                    Text(replyError)
                        .font(Typography.uiCaption())
                        .foregroundStyle(Color(hex: "CE514D"))
                }

                HStack(spacing: 8) {
                    Button {
                        Task { await submitReply(parentId: parentId) }
                    } label: {
                        Text(isSubmittingReply ? "Posting…" : "Post reply")
                            .font(Typography.smallButtonLabel())
                            .foregroundStyle(theme.onAccent)
                            .padding(.horizontal, 16)
                            .frame(height: 32)
                            .background(
                                RoundedRectangle(cornerRadius: Radius.chip)
                                    .fill(replyText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? theme.ink3 : theme.accent)
                            )
                    }
                    .disabled(isSubmittingReply || replyText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

                    Button {
                        replyingTo = nil
                    } label: {
                        Text("Cancel")
                            .font(Typography.smallButtonLabel())
                            .foregroundStyle(theme.ink3)
                    }
                }
            }
        }
        .padding(.vertical, 4)
    }

    // MARK: - Page Controls

    private var pageControls: some View {
        VStack(spacing: 12) {
            if isLoadingAll {
                HStack(spacing: 10) {
                    ProgressView()
                        .scaleEffect(0.8)
                    Text("Loading page \(loadAllProgress) of \(totalPages)…")
                        .font(Typography.uiSmall())
                        .foregroundStyle(theme.ink3)
                }
                .frame(maxWidth: .infinity)
                .padding(.top, 16)
            } else {
                HStack(spacing: 12) {
                    Button {
                        Task { await loadNextPage() }
                    } label: {
                        Text("Load more")
                            .font(Typography.smallButtonLabel())
                            .foregroundStyle(theme.ink)
                            .frame(maxWidth: .infinity)
                            .frame(height: 40)
                            .background(
                                RoundedRectangle(cornerRadius: Radius.button)
                                    .stroke(theme.line, lineWidth: 1)
                            )
                    }
                    .buttonStyle(ButtonPressStyle())
                    .disabled(isLoading)

                    Button {
                        Task { await loadAllPages() }
                    } label: {
                        Text("Load all")
                            .font(Typography.smallButtonLabel())
                            .foregroundStyle(theme.ink)
                            .frame(maxWidth: .infinity)
                            .frame(height: 40)
                            .background(
                                RoundedRectangle(cornerRadius: Radius.button)
                                    .stroke(theme.line, lineWidth: 1)
                            )
                    }
                    .buttonStyle(ButtonPressStyle())
                    .disabled(isLoading)
                }
                .padding(.top, 16)

                Text("Page \(currentPage) of \(totalPages)")
                    .font(Typography.uiCaption())
                    .foregroundStyle(theme.ink3)
                    .frame(maxWidth: .infinity)
            }
        }
    }

    // MARK: - Post Comment Button

    private var postCommentButton: some View {
        VStack(spacing: 0) {
            Divider().foregroundStyle(theme.line)
            Button {
                nav.presentedSheet = .comment(workID: workID, chapterID: chapterID)
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "bubble.right")
                        .font(.system(size: 14, weight: .semibold))
                    Text("Leave a comment")
                        .font(Typography.smallButtonLabel())
                }
                .foregroundStyle(theme.onAccent)
                .frame(maxWidth: .infinity)
                .frame(height: 44)
                .background(RoundedRectangle(cornerRadius: Radius.button).fill(theme.accent))
            }
            .buttonStyle(ButtonPressStyle())
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
        }
        .background(theme.surface)
    }

    // MARK: - Data Loading

    private func loadInitial() async {
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

        await loadPage(1, replace: true)
    }

    private func fetchPage(_ page: UInt32) async throws -> UCommentsPage {
        guard let wid = UInt64(workID) else {
            throw Ao3Error.Network(message: "Invalid work ID")
        }
        if let cid = chapterID, cid > 0 {
            return try await state.bridge.fetchChapterComments(workId: wid, chapterId: cid, page: page)
        } else {
            return try await state.bridge.fetchWorkComments(workId: wid, page: page)
        }
    }

    private func loadPage(_ page: UInt32, replace: Bool) async {
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
                comments.append(contentsOf: newComments)
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
            commentTask.reset()
            do {
                let result = try await state.retryOnTimeout(task: commentTask, using: state.bridge) {
                    try await self.fetchPage(nextPage)
                }
                let newComments = ParsedComment.fromJSON(result.commentsJson)
                comments.append(contentsOf: newComments)
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

    private func submitReply(parentId: UInt64) async {
        let trimmed = replyText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        isSubmittingReply = true
        replyError = nil
        do {
            let posted = try await state.bridge.postReply(parentCommentId: parentId, comment: trimmed)
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
