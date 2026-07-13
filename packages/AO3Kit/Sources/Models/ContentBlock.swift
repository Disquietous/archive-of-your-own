import Foundation

enum ContentBlock: Hashable {
    case paragraph(text: [InlineContent])
    case heading(level: Int, text: String)
    case blockquote(blocks: [ContentBlock])
    case horizontalRule
    case list(ordered: Bool, items: [[ContentBlock]])
}

enum InlineContent: Hashable {
    case text(value: String)
    case bold(content: [InlineContent])
    case italic(content: [InlineContent])
    case link(href: String, content: [InlineContent])
    case lineBreak
}
