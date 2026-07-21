import SwiftUI

struct InboxThreadView: View {
    @Bindable var theme: AppTheme
    @Bindable var appState: AppState

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
                    if let item = appState.selectedInboxItem {
                        threadHeader(item)
                    }
                    ForEach(appState.inboxThread) { comment in
                        AnyView(commentView(comment, depth: 0))
                    }
                }
                .padding(.bottom, 40)
            }
        }
        .background(theme.bg)
    }

    private func threadHeader(_ item: InboxItem) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(item.workReference)
                .font(Font(MacFont.serif(20, weight: .semibold)))
                .foregroundStyle(theme.ink)
            Text("Comment thread")
                .font(Font(MacFont.ui(12, weight: .medium)))
                .foregroundStyle(theme.ink3)
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 16)
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

}
