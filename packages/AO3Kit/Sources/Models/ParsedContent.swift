import Foundation

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
