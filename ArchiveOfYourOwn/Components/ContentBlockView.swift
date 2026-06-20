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

// MARK: - Swift-native content block types (parsed from JSON or mock data)

enum ParsedContentBlock: Hashable {
    case paragraph(text: [ParsedInlineContent])
    case heading(level: Int, text: String)
    case blockquote(blocks: [ParsedContentBlock])
    case horizontalRule
    case list(ordered: Bool, items: [[ParsedContentBlock]])
    case preFormatted(text: String)

    static func fromJSON(_ json: String) -> [ParsedContentBlock] {
        guard let data = json.data(using: .utf8),
              let raw = try? JSONDecoder().decode([RawContentBlock].self, from: data) else {
            return []
        }
        return raw.map { $0.toParsed() }
    }

    static func fromParagraphs(_ paragraphs: [String]) -> [ParsedContentBlock] {
        paragraphs.map { .paragraph(text: [.text(value: $0)]) }
    }
}

enum ParsedInlineContent: Hashable {
    case text(value: String)
    case bold(content: [ParsedInlineContent])
    case italic(content: [ParsedInlineContent])
    case link(href: String, content: [ParsedInlineContent])
    case strikethrough(content: [ParsedInlineContent])
    case superscript(content: [ParsedInlineContent])
    case lineBreak
}

// MARK: - JSON Decoding for Rust ContentBlock
// Rust serde externally-tagged enum format:
//   {"Paragraph": {"text": [...]}}
//   {"Heading": {"level": 2, "text": "..."}}
//   "HorizontalRule"
//   {"Text": {"value": "..."}}
//   "LineBreak"

private enum RawContentBlock: Decodable {
    case paragraph([RawInlineContent])
    case heading(Int, String)
    case blockquote([RawContentBlock])
    case horizontalRule
    case list(Bool, [[RawContentBlock]])
    case preFormatted(String)
    case unknown

    private struct ParagraphPayload: Decodable { let text: [RawInlineContent] }
    private struct HeadingPayload: Decodable { let level: Int; let text: String }
    private struct BlockquotePayload: Decodable { let blocks: [RawContentBlock] }
    private struct ListPayload: Decodable { let ordered: Bool; let items: [[RawContentBlock]] }
    private struct PreFormattedPayload: Decodable { let text: String }

    private enum Tag: String, CodingKey {
        case Paragraph, Heading, Blockquote, HorizontalRule, List, PreFormatted
    }

    init(from decoder: Decoder) throws {
        // Try as string first ("HorizontalRule")
        if let container = try? decoder.singleValueContainer(),
           let s = try? container.decode(String.self) {
            if s == "HorizontalRule" { self = .horizontalRule; return }
            self = .unknown; return
        }
        // Otherwise it's {"Tag": {payload}}
        let container = try decoder.container(keyedBy: Tag.self)
        if let p = try? container.decode(ParagraphPayload.self, forKey: .Paragraph) {
            self = .paragraph(p.text); return
        }
        if let h = try? container.decode(HeadingPayload.self, forKey: .Heading) {
            self = .heading(h.level, h.text); return
        }
        if let b = try? container.decode(BlockquotePayload.self, forKey: .Blockquote) {
            self = .blockquote(b.blocks); return
        }
        if container.contains(.HorizontalRule) {
            self = .horizontalRule; return
        }
        if let l = try? container.decode(ListPayload.self, forKey: .List) {
            self = .list(l.ordered, l.items); return
        }
        if let p = try? container.decode(PreFormattedPayload.self, forKey: .PreFormatted) {
            self = .preFormatted(p.text); return
        }
        self = .unknown
    }

    func toParsed() -> ParsedContentBlock {
        switch self {
        case .paragraph(let inlines): .paragraph(text: inlines.map { $0.toParsed() })
        case .heading(let level, let text): .heading(level: level, text: text)
        case .blockquote(let blocks): .blockquote(blocks: blocks.map { $0.toParsed() })
        case .horizontalRule: .horizontalRule
        case .list(let ordered, let items): .list(ordered: ordered, items: items.map { $0.map { $0.toParsed() } })
        case .preFormatted(let text): .preFormatted(text: text)
        case .unknown: .paragraph(text: [])
        }
    }
}

private indirect enum RawInlineContent: Decodable {
    case text(String)
    case bold([RawInlineContent])
    case italic([RawInlineContent])
    case link(String, [RawInlineContent])
    case strikethrough([RawInlineContent])
    case superscript([RawInlineContent])
    case lineBreak

    private struct TextPayload: Decodable { let value: String }
    private struct ContentPayload: Decodable { let content: [RawInlineContent] }
    private struct LinkPayload: Decodable { let href: String; let content: [RawInlineContent] }

    private enum Tag: String, CodingKey {
        case Text, Bold, Italic, Link, Strikethrough, Superscript, LineBreak
    }

    init(from decoder: Decoder) throws {
        // "LineBreak" as bare string
        if let container = try? decoder.singleValueContainer(),
           let s = try? container.decode(String.self) {
            if s == "LineBreak" { self = .lineBreak; return }
            self = .text(s); return
        }
        // {"Tag": {payload}}
        let container = try decoder.container(keyedBy: Tag.self)
        if let t = try? container.decode(TextPayload.self, forKey: .Text) {
            self = .text(t.value); return
        }
        if let b = try? container.decode(ContentPayload.self, forKey: .Bold) {
            self = .bold(b.content); return
        }
        if let i = try? container.decode(ContentPayload.self, forKey: .Italic) {
            self = .italic(i.content); return
        }
        if let l = try? container.decode(LinkPayload.self, forKey: .Link) {
            self = .link(l.href, l.content); return
        }
        if let s = try? container.decode(ContentPayload.self, forKey: .Strikethrough) {
            self = .strikethrough(s.content); return
        }
        if let s = try? container.decode(ContentPayload.self, forKey: .Superscript) {
            self = .superscript(s.content); return
        }
        if container.contains(.LineBreak) {
            self = .lineBreak; return
        }
        self = .text("")
    }

    func toParsed() -> ParsedInlineContent {
        switch self {
        case .text(let v): .text(value: v)
        case .bold(let c): .bold(content: c.map { $0.toParsed() })
        case .italic(let c): .italic(content: c.map { $0.toParsed() })
        case .link(let h, let c): .link(href: h, content: c.map { $0.toParsed() })
        case .strikethrough(let c): .strikethrough(content: c.map { $0.toParsed() })
        case .superscript(let c): .superscript(content: c.map { $0.toParsed() })
        case .lineBreak: .lineBreak
        }
    }
}
