import SwiftUI

struct InboxThreadView: View {
    @Bindable var theme: AppTheme
    @Bindable var appState: AppState

    @State private var replyingTo: UInt64?
    @State private var replyText = ""
    @State private var isSubmittingReply = false
    @State private var replyError: String?
    @State private var replySuccess = false

    private var isLoggedIn: Bool { appState.ao3Username != nil }

    var body: some View {
        let _ = theme.uiFontScale  // track app text size so fonts refresh live
        ScrollView {
            if appState.isLoadingThread && appState.inboxThread.isEmpty {
                VStack(spacing: 12) {
                    ProgressView().controlSize(.regular)
                    Text("Loading thread…")
                        .font(Font(MacFont.ui(13)))
                        .foregroundStyle(theme.ink3)
                }
                .frame(maxWidth: .infinity)
                .padding(.top, 80)
            } else if let error = appState.threadError, appState.inboxThread.isEmpty {
                VStack(spacing: 12) {
                    Image(systemName: "exclamationmark.triangle")
                        .font(.system(size: 28, weight: .light))
                        .foregroundStyle(theme.ink3)
                    Text("Couldn't load thread")
                        .font(Font(MacFont.serif(18, weight: .semibold)))
                        .foregroundStyle(theme.ink2)
                    Text(error)
                        .font(Font(MacFont.ui(13)))
                        .foregroundStyle(theme.ink3)
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity)
                .padding(.top, 80)
                .padding(.horizontal, 24)
            } else {
                VStack(alignment: .leading, spacing: 0) {
                    if appState.isLoadingThread {
                        statusRow(spinner: true, text: "Refreshing from AO3…")
                    } else if let error = appState.threadError {
                        statusRow(spinner: false, text: "Refresh failed: \(error)")
                    }
                    ForEach(appState.inboxThread) { comment in
                        AnyView(commentView(comment, depth: 0))
                    }
                }
                .padding(.bottom, 40)
            }
        }
        .background(theme.bg)
        .onChange(of: appState.selectedInboxItem?.commentId) {
            replyingTo = nil
            replyText = ""
            replyError = nil
            replySuccess = false
        }
    }

    /// A refresh in flight, or its failure, shown above the cached thread
    /// that stays on screen.
    private func statusRow(spinner: Bool, text: String) -> some View {
        HStack(spacing: 8) {
            if spinner { ProgressView().controlSize(.small) }
            Text(text)
                .font(Font(MacFont.ui(12)))
                .foregroundStyle(theme.ink3)
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .overlay(alignment: .bottom) { theme.line.frame(height: 1) }
    }

    private func commentView(_ comment: InboxThreadComment, depth: Int) -> some View {
        let isTarget = comment.id == appState.selectedInboxItem?.commentId
        return VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .center, spacing: 8) {
                    AuthorAvatarView(theme: theme, appState: appState,
                                     username: comment.author,
                                     urlHint: comment.avatarUrl.isEmpty ? nil : comment.avatarUrl,
                                     size: 24,
                                     fetchable: !comment.authorUrl.isEmpty || !comment.avatarUrl.isEmpty)
                    Text(comment.author)
                        .font(Font(MacFont.ui(13, weight: .bold)))
                        .foregroundStyle(isTarget ? theme.accent : theme.ink)
                    if isTarget {
                        Text("·")
                            .foregroundStyle(theme.ink3)
                        Text("this message")
                            .font(Font(MacFont.ui(11, weight: .semibold)))
                            .foregroundStyle(theme.accent)
                    }
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
            .padding(.horizontal, 24)
            .padding(.vertical, 14)
            .padding(.leading, CGFloat(depth) * 20)
            .background(isTarget ? theme.accent.opacity(0.06) : .clear)
            .overlay(alignment: .bottom) { theme.line.frame(height: 1) }

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

    /// Post the reply; on success the core has already added it to the
    /// cached thread and the state re-read it, so the new reply appears
    /// beneath its parent without a fetch.
    private func submitReply(parentId: UInt64) async {
        let trimmed = replyText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        isSubmittingReply = true
        replyError = nil
        do {
            let posted = try await appState.postInboxReply(parentId: parentId, text: trimmed)
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
