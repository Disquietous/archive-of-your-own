import SwiftUI

struct InboxThreadView: View {
    @Bindable var theme: AppTheme
    @Bindable var appState: AppState

    var body: some View {
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
                HStack(alignment: .firstTextBaseline) {
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
                    commentContent(blocks)
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

    private func commentContent(_ blocks: [ParsedContentBlock]) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                AnyView(blockView(block))
            }
        }
    }

    @ViewBuilder
    private func blockView(_ block: ParsedContentBlock) -> some View {
        switch block {
        case .paragraph(let inlines):
            inlineText(inlines)
                .font(Font(MacFont.ui(13)))
                .foregroundStyle(theme.ink2)
        case .heading(_, let text):
            Text(text)
                .font(Font(MacFont.ui(13, weight: .bold)))
                .foregroundStyle(theme.ink)
        case .blockquote(let nested):
            VStack(alignment: .leading, spacing: 4) {
                ForEach(Array(nested.enumerated()), id: \.offset) { _, b in
                    AnyView(blockView(b))
                }
            }
            .padding(.leading, 12)
            .overlay(alignment: .leading) {
                Rectangle().fill(theme.ink3.opacity(0.3)).frame(width: 3)
            }
        case .list(let ordered, let items):
            VStack(alignment: .leading, spacing: 2) {
                ForEach(Array(items.enumerated()), id: \.offset) { i, itemBlocks in
                    HStack(alignment: .top, spacing: 4) {
                        Text(ordered ? "\(i + 1)." : "•")
                            .font(Font(MacFont.ui(13)))
                            .foregroundStyle(theme.ink3)
                        VStack(alignment: .leading, spacing: 2) {
                            ForEach(Array(itemBlocks.enumerated()), id: \.offset) { _, b in
                                AnyView(blockView(b))
                            }
                        }
                    }
                }
            }
        case .horizontalRule:
            theme.line.frame(height: 1).padding(.vertical, 4)
        case .preFormatted(let text):
            Text(text)
                .font(.system(size: 12, design: .monospaced))
                .foregroundStyle(theme.ink2)
                .padding(8)
                .background(theme.surface)
                .clipShape(RoundedRectangle(cornerRadius: 6))
        }
    }

    private func inlineText(_ inlines: [ParsedInlineContent]) -> Text {
        inlines.reduce(Text("")) { result, inline in
            result + renderInline(inline)
        }
    }

    private func renderInline(_ inline: ParsedInlineContent) -> Text {
        switch inline {
        case .text(let value):
            return Text(value)
        case .bold(let content):
            return content.reduce(Text("")) { $0 + renderInline($1) }.bold()
        case .italic(let content):
            return content.reduce(Text("")) { $0 + renderInline($1) }.italic()
        case .link(_, let content):
            return content.reduce(Text("")) { $0 + renderInline($1) }
                .foregroundColor(Color(theme.accent))
        case .strikethrough(let content):
            return content.reduce(Text("")) { $0 + renderInline($1) }.strikethrough()
        case .superscript(let content):
            return content.reduce(Text("")) { $0 + renderInline($1) }
                .font(Font(MacFont.ui(10)))
                .baselineOffset(4)
        case .lineBreak:
            return Text("\n")
        }
    }
}
