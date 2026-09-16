import SwiftUI

/// One inbox message's comment thread (cached copy first, refreshed from
/// AO3), with inline reply under any comment when signed in.
struct InboxThreadView: View {
    @Environment(AppTheme.self) private var theme
    @Environment(AppState.self) private var state

    @State private var replyingTo: UInt64?
    @State private var replyText = ""
    @State private var isSubmittingReply = false
    @State private var replyError: String?
    @State private var replySuccess = false
    @State private var avatarCache: [String: UIImage] = [:]

    private var isLoggedIn: Bool { state.ao3Username != nil }

    var body: some View {
        ZStack(alignment: .top) {
            ScrollView {
                if state.isLoadingThread && state.inboxThread.isEmpty {
                    NetworkLoadingView(message: "Loading thread…", task: state.inboxTask, operation: "inbox_thread") {
                        state.inboxTask.cancel()
                    }
                    .padding(.top, 40)
                } else if let error = state.threadError, state.inboxThread.isEmpty {
                    NetworkErrorView(message: error, onRetry: {
                        Task { await state.refreshInboxThread() }
                    })
                    .padding(.top, 40)
                } else {
                    VStack(alignment: .leading, spacing: 0) {
                        if state.isLoadingThread {
                            statusRow(spinner: true, text: "Refreshing from AO3…")
                        } else if let error = state.threadError {
                            statusRow(spinner: false, text: "Refresh failed: \(error)")
                        }
                        ForEach(state.inboxThread) { comment in
                            AnyView(commentView(comment, depth: 0))
                        }
                    }
                    .padding(.bottom, 40)
                }
            }
            .contentMargins(.top, ScreenChromeMetrics.height, for: .scrollContent)
            .scrollDismissesKeyboard(.interactively)

            ScreenChrome(title: state.selectedInboxItem?.author ?? "Thread",
                         subtitle: state.selectedInboxItem.map { "on \($0.workReference)" }) {
                ChromeIconButton(symbol: "arrow.clockwise", isBusy: state.isLoadingThread) {
                    Task { await state.refreshInboxThread() }
                }
                .disabled(state.isLoadingThread)
            }
        }
        .libraryScreen()
        .onDisappear { state.clearInboxSelection() }
    }

    private func statusRow(spinner: Bool, text: String) -> some View {
        HStack(spacing: 8) {
            if spinner { ProgressView().controlSize(.small) }
            Text(text)
                .font(.custom("HankenGrotesk", size: 12))
                .foregroundStyle(theme.ink3)
        }
        .padding(.horizontal, theme.pad)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .overlay(alignment: .bottom) { theme.line.frame(height: 1) }
    }

    private func commentView(_ comment: InboxThreadComment, depth: Int) -> some View {
        let isTarget = comment.id == state.selectedInboxItem?.commentId
        return VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .center, spacing: 8) {
                    avatar(comment)
                    Text(comment.author)
                        .font(.custom("HankenGrotesk", size: 14).weight(.bold))
                        .foregroundStyle(isTarget ? theme.accent : theme.ink)
                        .lineLimit(1)
                    if isTarget {
                        Text("· this message")
                            .font(.custom("HankenGrotesk", size: 11).weight(.semibold))
                            .foregroundStyle(theme.accent)
                    }
                    Spacer()
                    Text(comment.postedAt)
                        .font(.custom("HankenGrotesk", size: 11))
                        .foregroundStyle(theme.ink3)
                }

                let blocks = ParsedContentBlock.fromJSON(comment.contentJson)
                if !blocks.isEmpty {
                    ContentBlockView(blocks: blocks, compact: true)
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
                            .font(.custom("HankenGrotesk", size: 12.5).weight(.semibold))
                            .foregroundStyle(theme.accent)
                    }
                    .buttonStyle(.plain)

                    if replyingTo == comment.id {
                        replyField(parentId: comment.id)
                    }
                }
            }
            .padding(.horizontal, theme.pad)
            .padding(.vertical, 14)
            .padding(.leading, CGFloat(min(depth, 4)) * 16)
            .background(isTarget ? theme.accent.opacity(0.06) : .clear)
            .overlay(alignment: .bottom) { theme.line.frame(height: 1) }

            ForEach(comment.replies) { reply in
                AnyView(commentView(reply, depth: depth + 1))
            }
        }
    }

    @ViewBuilder
    private func avatar(_ comment: InboxThreadComment) -> some View {
        let size: CGFloat = 26
        if let cached = avatarCache[comment.author] {
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
                    Text(String(comment.author.prefix(1)).uppercased())
                        .font(.custom("HankenGrotesk", size: 12).weight(.bold))
                        .foregroundStyle(theme.ink3)
                }
                .task {
                    guard !comment.avatarUrl.isEmpty, avatarCache[comment.author] == nil else { return }
                    if let data = try? await state.bridge.fetchImage(url: comment.avatarUrl),
                       let image = UIImage(data: data) {
                        avatarCache[comment.author] = image
                    }
                }
        }
    }

    @ViewBuilder
    private func replyField(parentId: UInt64) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            if replySuccess {
                Text("Reply posted!")
                    .font(.custom("HankenGrotesk", size: 12.5).weight(.semibold))
                    .foregroundStyle(theme.sage)
            } else {
                TextEditor(text: $replyText)
                    .font(.custom("HankenGrotesk", size: 14))
                    .foregroundStyle(theme.ink)
                    .scrollContentBackground(.hidden)
                    .padding(8)
                    .frame(minHeight: 70, maxHeight: 140)
                    .background(theme.surface2)
                    .clipShape(RoundedRectangle(cornerRadius: 10))

                if let replyError {
                    Text(replyError)
                        .font(.custom("HankenGrotesk", size: 12))
                        .foregroundStyle(Color(hex: "CE514D"))
                }

                HStack(spacing: 12) {
                    Button {
                        Task { await submitReply(parentId: parentId) }
                    } label: {
                        Text(isSubmittingReply ? "Posting…" : "Post reply")
                            .font(.custom("HankenGrotesk", size: 13).weight(.bold))
                            .foregroundStyle(theme.onAccent)
                            .padding(.horizontal, 16)
                            .frame(height: 34)
                            .background(replyDisabled ? theme.ink3 : theme.accent)
                            .clipShape(Capsule())
                    }
                    .buttonStyle(ButtonPressStyle())
                    .disabled(isSubmittingReply || replyDisabled)

                    Button("Cancel") { replyingTo = nil }
                        .buttonStyle(.plain)
                        .font(.custom("HankenGrotesk", size: 13).weight(.semibold))
                        .foregroundStyle(theme.ink3)
                }
            }
        }
        .padding(.top, 4)
    }

    private var replyDisabled: Bool {
        replyText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func submitReply(parentId: UInt64) async {
        let trimmed = replyText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        isSubmittingReply = true
        replyError = nil
        do {
            let posted = try await state.postInboxReply(parentId: parentId, text: trimmed)
            if posted {
                replySuccess = true
                replyText = ""
                try? await Task.sleep(for: .seconds(1.5))
                replyingTo = nil
                replySuccess = false
            } else {
                replyError = "Failed to post reply."
            }
        } catch {
            replyError = error.localizedDescription
        }
        isSubmittingReply = false
    }
}
