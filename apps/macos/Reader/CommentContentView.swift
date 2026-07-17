import SwiftUI

/// Renders a comment body's ParsedContentBlock tree in the mac chrome type.
/// Shared by the inbox thread view and the work/chapter comments view.
struct CommentContentView: View {
    let theme: AppTheme
    let blocks: [ParsedContentBlock]

    var body: some View {
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
