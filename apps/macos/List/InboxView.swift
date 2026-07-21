import SwiftUI

struct InboxView: View {
    @Bindable var theme: AppTheme
    @Bindable var appState: AppState
    @Bindable var model: MacAppModel

    var body: some View {
        let _ = theme.uiFontScale  // track app text size so fonts refresh live
        ScrollView {
            if appState.isLoadingInbox && appState.inboxMessages.isEmpty {
                LoadingStateMac(theme: theme, message: "Loading inbox…")
            } else if let error = appState.inboxError, appState.inboxMessages.isEmpty {
                EmptyStateMac(theme: theme, icon: "exclamationmark.triangle",
                              title: "Couldn't load inbox", message: error)
            } else if appState.inboxMessages.isEmpty {
                EmptyStateMac(theme: theme, icon: "tray",
                              title: "Inbox empty",
                              message: "Comment threads from your AO3 inbox appear here.")
            } else {
                LazyVStack(spacing: 0) {
                    ForEach(model.filteredInboxMessages) { item in
                        messageRow(item)
                    }
                }
            }
        }
    }

    private func messageRow(_ item: InboxItem) -> some View {
        let selected = appState.selectedInboxItem?.commentId == item.commentId
        return Button {
            appState.selectInboxMessage(item)
        } label: {
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .top, spacing: 8) {
                    if item.isUnread {
                        Circle()
                            .fill(selected ? theme.onAccent : theme.accent)
                            .frame(width: 8, height: 8)
                            .padding(.top, 5)
                    }
                    AuthorAvatarView(theme: theme, appState: appState,
                                     username: item.author,
                                     urlHint: item.avatarUrl.isEmpty ? nil : item.avatarUrl,
                                     size: 28,
                                     fetchable: !item.authorUrl.isEmpty || !item.avatarUrl.isEmpty)
                    VStack(alignment: .leading, spacing: 4) {
                        HStack(alignment: .firstTextBaseline) {
                            Text(item.author)
                                .font(Font(MacFont.ui(13, weight: .bold)))
                                .foregroundStyle(selected ? theme.onAccent : theme.ink)
                            Spacer()
                            Text(item.postedAt)
                                .font(Font(MacFont.ui(11)))
                                .foregroundStyle(selected ? theme.onAccent.opacity(0.7) : theme.ink3)
                        }
                        if !item.workReference.isEmpty {
                            Text("on ")
                                .font(Font(MacFont.ui(12)))
                                .foregroundStyle(selected ? theme.onAccent.opacity(0.7) : theme.ink3)
                            + Text(item.workReference)
                                .font(Font(MacFont.ui(12, weight: .semibold)))
                                .foregroundStyle(selected ? theme.onAccent : theme.accent)
                        }
                    }
                }

                let blocks = ParsedContentBlock.fromJSON(item.contentJson)
                if !blocks.isEmpty {
                    contentView(blocks)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .background(selected ? theme.accent : (item.isUnread ? theme.accent.opacity(0.04) : .clear))
            .overlay(alignment: .bottom) { theme.line.frame(height: 1) }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func contentView(_ blocks: [ParsedContentBlock]) -> some View {
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
