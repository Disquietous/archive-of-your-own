import Foundation

/// Where the panel's clickable things go — supplied by the host so the
/// panel never reaches into window/model plumbing itself.
struct DiscussionActions {
    var openAuthor: (String) -> Void
    var openURL: (URL) -> Void
}

/// Plain-text and time helpers for comments.
enum DiscussionText {
    static func plain(_ comment: ParsedComment) -> String {
        plain(ParsedContentBlock.fromJSON(comment.contentJson))
    }

    static func plain(_ blocks: [ParsedContentBlock]) -> String {
        blocks.map(plain).joined(separator: "\n\n")
    }

    private static func plain(_ block: ParsedContentBlock) -> String {
        switch block {
        case .paragraph(let inlines): return inlines.map(plain).joined()
        case .heading(_, let text): return text
        case .blockquote(let nested): return nested.map(plain).joined(separator: "\n")
        case .list(_, let items): return items.map { $0.map(plain).joined(separator: " ") }.joined(separator: "\n")
        case .horizontalRule: return "—"
        case .preFormatted(let text): return text
        case .image(_, let alt): return alt
        }
    }

    private static func plain(_ inline: ParsedInlineContent) -> String {
        switch inline {
        case .text(let value): return value
        case .bold(let c), .italic(let c), .strikethrough(let c), .superscript(let c):
            return c.map(plain).joined()
        case .link(_, let c): return c.map(plain).joined()
        case .lineBreak: return "\n"
        }
    }

    static func snippet(_ comment: ParsedComment, limit: Int = 80) -> String {
        let text = plain(comment).split(whereSeparator: \.isNewline).joined(separator: " ")
        return text.count > limit ? String(text.prefix(limit)) + "…" : text
    }

    static func commentURL(_ id: UInt64) -> URL {
        URL(string: "https://archiveofourown.org/comments/\(id)")!
    }

    private static let parser: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "d MMM yyyy hh:mma zzz"
        return f
    }()

    /// AO3's "17 Jul 2026 03:12AM EDT" as a date; nil for other shapes.
    static func date(_ posted: String) -> Date? {
        parser.date(from: posted)
    }

    /// "now", "5m", "3h", "4d", else a short date. Falls back to AO3's text.
    static func relative(_ posted: String, now: Date = Date()) -> String {
        guard let date = date(posted) else { return posted }
        let seconds = max(0, now.timeIntervalSince(date))
        switch seconds {
        case ..<60: return "now"
        case ..<3600: return "\(Int(seconds / 60))m"
        case ..<86_400: return "\(Int(seconds / 3600))h"
        case ..<(86_400 * 30): return "\(Int(seconds / 86_400))d"
        default: return date.formatted(date: .abbreviated, time: .omitted)
        }
    }
}
