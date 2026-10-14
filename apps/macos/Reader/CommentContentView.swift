import SwiftUI

/// Renders a comment body's ParsedContentBlock tree in the mac chrome type.
/// Shared by the inbox thread view and the discussion panel. Text is
/// selectable and links are live — the host decides where a link goes via
/// the `openURL` environment. `highlight` tints case-insensitive matches
/// (find in comments).
struct CommentContentView: View {
    let theme: AppTheme
    let blocks: [ParsedContentBlock]
    var highlight: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                AnyView(blockView(block))
            }
        }
        .textSelection(.enabled)
    }

    @ViewBuilder
    private func blockView(_ block: ParsedContentBlock) -> some View {
        switch block {
        case .paragraph(let inlines):
            Text(attributed(inlines))
                .font(Font(MacFont.ui(13)))
                .foregroundStyle(theme.ink2)
                .fixedSize(horizontal: false, vertical: true)
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
        case .image(_, let alt):
            // Comments stay text-only; note the image rather than fetch it.
            Text(alt.isEmpty ? "[image]" : "[image: \(alt)]")
                .font(Font(MacFont.ui(12)).italic())
                .foregroundStyle(theme.ink3)
        }
    }

    private func attributed(_ inlines: [ParsedInlineContent]) -> AttributedString {
        var result = inlines.reduce(into: AttributedString()) { $0 += render($1) }
        if let query = highlight?.trimmingCharacters(in: .whitespaces), !query.isEmpty {
            var searchStart = result.startIndex
            while searchStart < result.endIndex,
                  let range = result[searchStart...].range(of: query, options: .caseInsensitive) {
                result[range].backgroundColor = theme.accent.opacity(0.28)
                searchStart = range.upperBound
            }
        }
        return result
    }

    /// Add an intent run by run, so bold inside italic keeps both.
    private func adding(_ intent: InlinePresentationIntent, to string: AttributedString) -> AttributedString {
        var s = string
        for run in string.runs {
            s[run.range].inlinePresentationIntent = (run.inlinePresentationIntent ?? []).union(intent)
        }
        return s
    }

    private func render(_ inline: ParsedInlineContent) -> AttributedString {
        func joined(_ content: [ParsedInlineContent]) -> AttributedString {
            content.reduce(into: AttributedString()) { $0 += render($1) }
        }
        switch inline {
        case .text(let value):
            return AttributedString(value)
        case .bold(let content):
            return adding(.stronglyEmphasized, to: joined(content))
        case .italic(let content):
            return adding(.emphasized, to: joined(content))
        case .link(let href, let content):
            var s = joined(content)
            s.foregroundColor = theme.accent
            if let url = URL(string: href, relativeTo: URL(string: "https://archiveofourown.org")) {
                s.link = url.absoluteURL
            }
            return s
        case .strikethrough(let content):
            var s = joined(content)
            s.strikethroughStyle = .single
            return s
        case .superscript(let content):
            var s = joined(content)
            s.font = Font(MacFont.ui(10))
            s.baselineOffset = 4
            return s
        case .lineBreak:
            return AttributedString("\n")
        }
    }
}
