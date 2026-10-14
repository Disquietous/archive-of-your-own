import SwiftUI

/// Loading / error / empty / no-match states, shown over the thread table
/// while it has no comment rows.
struct DiscussionStatesView: View {
    @Bindable var theme: AppTheme
    @Bindable var model: DiscussionModel

    var body: some View {
        let _ = theme.uiFontScale  // track app text size so fonts refresh live
        VStack {
            content
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(theme.bg)
    }

    @ViewBuilder
    private var content: some View {
        if model.comments.isEmpty && model.pending(under: nil).isEmpty {
            if model.isLoading {
                VStack(spacing: 12) {
                    ProgressView().controlSize(.regular)
                    Text("Loading comments…")
                        .font(Font(MacFont.ui(13)))
                        .foregroundStyle(theme.ink3)
                    Text(model.commentTask.statusMessage ?? "Requests are rate-limited to be kind to the archive.")
                        .font(Font(MacFont.ui(11.5)))
                        .foregroundStyle(theme.ink3)
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity)
                .padding(.top, 60)
                .padding(.horizontal, 20)
            } else if let error = model.loadError {
                VStack(spacing: 10) {
                    Image(systemName: "exclamationmark.triangle")
                        .font(.system(size: 22, weight: .light))
                        .foregroundStyle(theme.ink3)
                    Text("Couldn’t load comments")
                        .font(Font(MacFont.serif(15, weight: .semibold)))
                        .foregroundStyle(theme.ink2)
                    Text(error)
                        .font(Font(MacFont.ui(12)))
                        .foregroundStyle(theme.ink3)
                        .multilineTextAlignment(.center)
                    Button("Try Again") { model.startInitialLoad() }
                }
                .frame(maxWidth: .infinity)
                .padding(.top, 50)
                .padding(.horizontal, 20)
            } else if model.workID != nil {
                VStack(spacing: 8) {
                    Image(systemName: "bubble.left.and.bubble.right")
                        .font(.system(size: 24, weight: .light))
                        .foregroundStyle(theme.ink3)
                    Text("No comments on \(model.scopeTitle == "Whole work" ? "this work" : model.scopeTitle) yet.")
                        .font(Font(MacFont.ui(13, weight: .semibold)))
                        .foregroundStyle(theme.ink2)
                    Text(model.isLoggedIn ? "Be the first — authors love hearing from readers." : "")
                        .font(Font(MacFont.ui(12)))
                        .foregroundStyle(theme.ink3)
                }
                .frame(maxWidth: .infinity)
                .padding(.top, 60)
            }
        } else if model.isFinding, !model.findText.isEmpty {
            message("No loaded comments match “\(model.findText)”.")
        } else if model.authorRepliesOnly {
            message("No threads with replies from the author in what’s loaded.")
        }
    }

    private func message(_ text: String) -> some View {
        Text(text)
            .font(Font(MacFont.ui(12.5)))
            .foregroundStyle(theme.ink3)
            .multilineTextAlignment(.center)
            .frame(maxWidth: .infinity)
            .padding(.top, 40)
            .padding(.horizontal, 20)
    }
}

/// The table's last row: "Showing X of Y", paging and load-all progress.
struct DiscussionFooterView: View {
    @Bindable var theme: AppTheme
    @Bindable var model: DiscussionModel

    static let height: CGFloat = 96

    var body: some View {
        let _ = theme.uiFontScale  // track app text size so fonts refresh live
        VStack(spacing: 8) {
            if model.isLoadingAll {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Loading page \(model.loadAllProgress) of \(model.totalPages)…")
                        .font(Font(MacFont.ui(12)))
                        .foregroundStyle(theme.ink3)
                    Button("Stop") { model.cancelLoadAll() }
                        .buttonStyle(.link)
                        .font(Font(MacFont.ui(12, weight: .semibold)))
                }
            } else if model.isLoading {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Loading comments…")
                        .font(Font(MacFont.ui(12)))
                        .foregroundStyle(theme.ink3)
                }
            } else {
                Text(showingText)
                    .font(Font(MacFont.ui(11.5)))
                    .foregroundStyle(theme.ink3)
                if model.hasMorePages {
                    HStack(spacing: 10) {
                        footerButton("Load next page") { model.loadNextPage() }
                        let remaining = model.totalPages - model.currentPage
                        footerButton("Load all (\(remaining) more page\(remaining == 1 ? "" : "s"))") {
                            model.loadAllPages()
                        }
                    }
                }
                if let error = model.loadError {
                    Text(error)
                        .font(Font(MacFont.ui(12)))
                        .foregroundStyle(theme.danger)
                        .multilineTextAlignment(.center)
                        .lineLimit(2)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .padding(.top, 14)
    }

    private var showingText: String {
        let loaded = model.loadedCount
        if let total = model.workTotal, model.hasMorePages {
            return "Showing \(loaded) of \(total)"
        }
        return model.hasMorePages
            ? "Showing \(loaded) · page \(model.currentPage) of \(model.totalPages)"
            : "\(loaded) comment\(loaded == 1 ? "" : "s")"
    }

    private func footerButton(_ label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(label)
                .font(Font(MacFont.ui(12, weight: .semibold)))
                .foregroundStyle(theme.ink2)
                .padding(.horizontal, 14)
                .frame(height: 28)
                .background(theme.surface)
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(theme.line, lineWidth: 1))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
