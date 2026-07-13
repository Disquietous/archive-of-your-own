import SwiftUI

struct ContentBlockView: View {
    @Environment(AppTheme.self) private var theme

    let blocks: [ParsedContentBlock]
    var compact: Bool = false
    var highlightedIndex: Int?

    var body: some View {
        ForEach(Array(blocks.enumerated()), id: \.offset) { index, block in
            blockView(block, isFirst: index == 0, previousBlock: index > 0 ? blocks[index - 1] : nil)
                .id("block-\(index)")
                .padding(.vertical, highlightedIndex == index ? 2 : 0)
                .background(
                    highlightedIndex == index
                        ? RoundedRectangle(cornerRadius: 4).fill(theme.accentSoft)
                        : RoundedRectangle(cornerRadius: 4).fill(.clear)
                )
        }
    }

    private func previousBlockAddsSpace(_ block: ParsedContentBlock?) -> Bool {
        guard let block else { return false }
        switch block {
        case .paragraph(let inlines):
            return trimmedInlines(inlines).isEmpty
        case .horizontalRule:
            return true
        default:
            return false
        }
    }

    @ViewBuilder
    private func blockView(_ block: ParsedContentBlock, isFirst: Bool, previousBlock: ParsedContentBlock? = nil) -> some View {
        switch block {
        case .paragraph(let inlines):
            Text(buildAttributedInlines(inlines))
                .font(compact ? Typography.uiBody() : theme.readingBodyFont)
                .lineSpacing(compact ? 4 : theme.readingLineSpacing)
                .foregroundStyle(theme.ink)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.top, !compact && !isFirst && !previousBlockAddsSpace(previousBlock) ? theme.readingLineSpacing * 1.0 : 0)

        case .heading(let level, let text):
            Text(text)
                .font(headingFont(level))
                .foregroundStyle(theme.ink)
                .padding(.top, level <= 2 ? 16 : 10)
                .frame(maxWidth: .infinity, alignment: .leading)

        case .blockquote(let inner):
            VStack(alignment: .leading, spacing: 8) {
                ContentBlockView(blocks: inner)
            }
            .padding(.leading, 16)
            .overlay(alignment: .leading) {
                Rectangle()
                    .fill(theme.line2)
                    .frame(width: 3)
            }
            .padding(.vertical, 4)

        case .horizontalRule:
            Rectangle()
                .fill(theme.ink)
                .frame(height: 1)
                .padding(.vertical, 12)

        case .list(let ordered, let items):
            VStack(alignment: .leading, spacing: 6) {
                ForEach(Array(items.enumerated()), id: \.offset) { i, itemBlocks in
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        if ordered {
                            Text("\(i + 1).")
                                .font(theme.readingBodyFont)
                                .foregroundStyle(theme.ink3)
                                .frame(width: 24, alignment: .trailing)
                        } else {
                            Text("•")
                                .font(theme.readingBodyFont)
                                .foregroundStyle(theme.ink3)
                                .frame(width: 16)
                        }
                        VStack(alignment: .leading, spacing: 4) {
                            ContentBlockView(blocks: itemBlocks)
                        }
                    }
                }
            }

        case .preFormatted(let text):
            Text(text)
                .font(.system(.body, design: .monospaced))
                .foregroundStyle(theme.ink2)
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(theme.surface2)
                .clipShape(RoundedRectangle(cornerRadius: 8))
        }
    }

    private func headingFont(_ level: Int) -> Font {
        switch level {
        case 1: .custom("Newsreader", size: 26).weight(.semibold)
        case 2: .custom("Newsreader", size: 22).weight(.semibold)
        case 3: .custom("Newsreader", size: 19).weight(.semibold)
        default: .custom("HankenGrotesk", size: 16).weight(.bold)
        }
    }

    private func trimmedInlines(_ inlines: [ParsedInlineContent]) -> [ParsedInlineContent] {
        var result = inlines
        while let first = result.first, case .text(let v) = first, v.allSatisfy({ $0.isWhitespace || $0.isNewline }) {
            result.removeFirst()
        }
        while let last = result.last, case .text(let v) = last, v.allSatisfy({ $0.isWhitespace || $0.isNewline }) {
            result.removeLast()
        }
        return result
    }

    private func buildAttributedInlines(_ inlines: [ParsedInlineContent]) -> AttributedString {
        var result = AttributedString()
        if !compact {
            result.append(AttributedString("\u{2002}\u{2002}\u{2002}\u{2002}"))
        }
        for inline in trimmedInlines(inlines) {
            result.append(attributedString(for: inline))
        }
        return result
    }

    private func attributedString(for inline: ParsedInlineContent) -> AttributedString {
        switch inline {
        case .text(let value):
            return AttributedString(value)

        case .bold(let content):
            var s = AttributedString()
            for c in content { s.append(attributedString(for: c)) }
            s.inlinePresentationIntent = .stronglyEmphasized
            return s

        case .italic(let content):
            var s = AttributedString()
            for c in content { s.append(attributedString(for: c)) }
            s.inlinePresentationIntent = .emphasized
            return s

        case .link(let href, let content):
            var s = AttributedString()
            for c in content { s.append(attributedString(for: c)) }
            if let url = URL(string: href) {
                s.link = url
            }
            return s

        case .strikethrough(let content):
            var s = AttributedString()
            for c in content { s.append(attributedString(for: c)) }
            s.strikethroughStyle = .single
            return s

        case .superscript(let content):
            var s = AttributedString()
            for c in content { s.append(attributedString(for: c)) }
            return s

        case .lineBreak:
            return AttributedString("\n")
        }
    }
}

struct DropCapParagraphView: View {
    @Environment(AppTheme.self) private var theme

    let inlines: [ParsedInlineContent]

    var body: some View {
        let fullText = plainText(from: inlines)
        if let first = fullText.first {
            HStack(alignment: .top, spacing: 0) {
                Text(String(first))
                    .font(.custom("Newsreader", size: CGFloat(Int(3.1 * 19))).weight(.semibold))
                    .foregroundStyle(theme.accent)
                    .lineLimit(1)
                    .padding(.trailing, 4)
                    .offset(y: -4)

                Text(buildAttributedInlines(Array(inlines.dropFirst(0)), skipFirst: true))
                    .font(theme.readingBodyFont)
                    .lineSpacing(theme.readingLineSpacing)
                    .foregroundStyle(theme.ink)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        } else {
            EmptyView()
        }
    }

    private func plainText(from inlines: [ParsedInlineContent]) -> String {
        inlines.map { inlineToString($0) }.joined()
    }

    private func inlineToString(_ inline: ParsedInlineContent) -> String {
        switch inline {
        case .text(let v): v
        case .bold(let c), .italic(let c), .link(_, let c),
             .strikethrough(let c), .superscript(let c): c.map { inlineToString($0) }.joined()
        case .lineBreak: "\n"
        }
    }

    private func buildAttributedInlines(_ inlines: [ParsedInlineContent], skipFirst: Bool) -> AttributedString {
        var result = AttributedString()
        var skipped = false
        for inline in inlines {
            if skipFirst && !skipped {
                if case .text(let v) = inline {
                    let trimmed = String(v.dropFirst())
                    if !trimmed.isEmpty {
                        result.append(AttributedString(trimmed))
                    }
                    skipped = true
                    continue
                }
            }
            result.append(attributedString(for: inline))
        }
        return result
    }

    private func attributedString(for inline: ParsedInlineContent) -> AttributedString {
        switch inline {
        case .text(let value):
            return AttributedString(value)
        case .bold(let content):
            var s = AttributedString()
            for c in content { s.append(attributedString(for: c)) }
            s.inlinePresentationIntent = .stronglyEmphasized
            return s
        case .italic(let content):
            var s = AttributedString()
            for c in content { s.append(attributedString(for: c)) }
            s.inlinePresentationIntent = .emphasized
            return s
        case .link(let href, let content):
            var s = AttributedString()
            for c in content { s.append(attributedString(for: c)) }
            if let url = URL(string: href) { s.link = url }
            return s
        case .strikethrough(let content):
            var s = AttributedString()
            for c in content { s.append(attributedString(for: c)) }
            s.strikethroughStyle = .single
            return s
        case .superscript(let content):
            var s = AttributedString()
            for c in content { s.append(attributedString(for: c)) }
            return s
        case .lineBreak:
            return AttributedString("\n")
        }
    }
}
