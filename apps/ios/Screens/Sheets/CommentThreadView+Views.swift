import SwiftUI

extension CommentThreadView {
    // MARK: - Comment View

    func commentView(_ comment: ParsedComment, depth: Int) -> AnyView {
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
    func avatarView(_ comment: ParsedComment) -> some View {
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

    func loadAvatar(for comment: ParsedComment) async {
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
    func replyField(parentId: UInt64) -> some View {
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

    var pageControls: some View {
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

    var postCommentButton: some View {
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
}
