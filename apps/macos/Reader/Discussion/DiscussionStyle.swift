import AppKit

/// Colors, fonts and geometry for the thread table, resolved once per
/// theme/text-size change rather than per cell or per frame.
struct DiscussionStyle {
    let bg, surface, surface2, ink, ink2, ink3, accent, accentSoft, line, line2, danger: NSColor
    let nameFont, timeFont, badgeFont, smallFont, linkFont, bodyFont, noticeFont: NSFont

    // Geometry (points). A comment box: 8 pad, 28 avatar, 10 gap, text.
    static let sideInset: CGFloat = 12
    static let indentStep: CGFloat = 36
    static let pad: CGFloat = 8
    static let avatar: CGFloat = 28
    static let textX: CGFloat = pad + avatar + 10
    static let bylineHeight: CGFloat = 18
    static let replyingHeight: CGFloat = 17
    static let linkRowHeight: CGFloat = 26
    static let separatorHeight: CGFloat = 9

    init(theme: AppTheme) {
        bg = theme.nsBg
        surface = theme.nsSurface
        surface2 = theme.nsSurface2
        ink = theme.nsInk
        ink2 = theme.nsInk2
        ink3 = theme.nsInk3
        accent = theme.nsAccent
        accentSoft = theme.nsAccentSoft
        line = theme.nsLine
        line2 = theme.nsLine2
        danger = NSColor(theme.danger)
        nameFont = MacFont.ui(13, weight: .bold)
        timeFont = MacFont.ui(11)
        badgeFont = MacFont.ui(10, weight: .semibold)
        smallFont = MacFont.ui(11)
        linkFont = MacFont.ui(11.5, weight: .semibold)
        bodyFont = MacFont.ui(13)
        noticeFont = ContentBlockRenderer.applyTraits(.italic, to: MacFont.ui(12))
    }

    /// The comment column inside a table of `width`: its left edge and width.
    /// Spans the full width (expanded included), less the side insets.
    static func column(in width: CGFloat) -> (x: CGFloat, width: CGFloat) {
        (sideInset, max(0, width - sideInset * 2))
    }

    /// Center x of the thread line for indent level `level`.
    static func guideX(level: Int, columnX: CGFloat) -> CGFloat {
        columnX + CGFloat(level) * indentStep + pad + avatar / 2
    }

    // MARK: - Comment bodies

    /// A comment body as one attributed string (selectable, live links,
    /// find matches tinted).
    func body(_ comment: ParsedComment, highlight: String?) -> NSAttributedString {
        let result = NSMutableAttributedString()
        if !comment.notice.isEmpty {
            result.append(NSAttributedString(string: comment.notice,
                                             attributes: [.font: noticeFont, .foregroundColor: ink3]))
        } else {
            for (i, block) in ParsedContentBlock.fromJSON(comment.contentJson).enumerated() {
                if i > 0 { result.append(NSAttributedString(string: "\n")) }
                let start = result.length
                append(block, to: result, indent: 0)
                let style = NSMutableParagraphStyle()
                style.paragraphSpacingBefore = i > 0 ? 6 : 0
                applyParagraph(style, from: start, in: result)
            }
        }
        if let query = highlight?.trimmingCharacters(in: .whitespaces), !query.isEmpty {
            let text = result.string as NSString
            var range = NSRange(location: 0, length: text.length)
            while range.length > 0 {
                let hit = text.range(of: query, options: .caseInsensitive, range: range)
                guard hit.location != NSNotFound else { break }
                result.addAttribute(.backgroundColor, value: accent.withAlphaComponent(0.28), range: hit)
                let next = hit.location + max(hit.length, 1)
                range = NSRange(location: next, length: text.length - next)
            }
        }
        return result
    }

    /// Keep each block's own indents; only add the inter-block spacing.
    private func applyParagraph(_ spacing: NSParagraphStyle, from start: Int, in result: NSMutableAttributedString) {
        let range = NSRange(location: start, length: result.length - start)
        guard range.length > 0 else { return }
        result.enumerateAttribute(.paragraphStyle, in: range) { value, sub, _ in
            let style = ((value as? NSParagraphStyle)?.mutableCopy() as? NSMutableParagraphStyle) ?? NSMutableParagraphStyle()
            style.paragraphSpacingBefore = spacing.paragraphSpacingBefore
            result.addAttribute(.paragraphStyle, value: style, range: sub)
        }
    }

    private func append(_ block: ParsedContentBlock, to result: NSMutableAttributedString, indent: CGFloat) {
        let style = NSMutableParagraphStyle()
        style.firstLineHeadIndent = indent
        style.headIndent = indent
        func add(_ s: NSAttributedString) {
            let m = NSMutableAttributedString(attributedString: s)
            m.addAttribute(.paragraphStyle, value: style, range: NSRange(location: 0, length: m.length))
            result.append(m)
        }
        switch block {
        case .paragraph(let inlines):
            add(inline(inlines, font: bodyFont, color: ink2))
        case .heading(_, let text):
            add(NSAttributedString(string: text, attributes: [.font: MacFont.ui(13, weight: .bold), .foregroundColor: ink]))
        case .blockquote(let nested):
            for (i, b) in nested.enumerated() {
                if i > 0 { result.append(NSAttributedString(string: "\n")) }
                append(b, to: result, indent: indent + 12)
            }
        case .list(let ordered, let items):
            for (i, item) in items.enumerated() {
                if i > 0 { result.append(NSAttributedString(string: "\n")) }
                let marker = NSAttributedString(string: ordered ? "\(i + 1).\t" : "•\t",
                                                attributes: [.font: bodyFont, .foregroundColor: ink3])
                let line = NSMutableAttributedString(attributedString: marker)
                let text = item.map { b -> NSAttributedString in
                    if case .paragraph(let inl) = b { return inline(inl, font: bodyFont, color: ink2) }
                    return NSAttributedString(string: DiscussionText.plain([b]),
                                              attributes: [.font: bodyFont, .foregroundColor: ink2])
                }
                text.enumerated().forEach { j, s in
                    if j > 0 { line.append(NSAttributedString(string: "\u{2028}")) }
                    line.append(s)
                }
                let listStyle = NSMutableParagraphStyle()
                listStyle.firstLineHeadIndent = indent
                listStyle.headIndent = indent + 16
                listStyle.tabStops = [NSTextTab(textAlignment: .left, location: indent + 16)]
                line.addAttribute(.paragraphStyle, value: listStyle, range: NSRange(location: 0, length: line.length))
                result.append(line)
            }
        case .horizontalRule:
            add(NSAttributedString(string: "———", attributes: [.font: bodyFont, .foregroundColor: line2]))
        case .preFormatted(let text):
            add(NSAttributedString(string: text, attributes: [
                .font: NSFont.monospacedSystemFont(ofSize: 12 * MacFont.scale, weight: .regular),
                .foregroundColor: ink2, .backgroundColor: surface,
            ]))
        case .image(_, let alt):
            add(NSAttributedString(string: alt.isEmpty ? "[image]" : "[image: \(alt)]",
                                   attributes: [.font: noticeFont, .foregroundColor: ink3]))
        }
    }

    private func inline(_ inlines: [ParsedInlineContent], font: NSFont, color: NSColor) -> NSAttributedString {
        let result = NSMutableAttributedString()
        for item in inlines { result.append(inline(item, font: font, color: color)) }
        return result
    }

    private func inline(_ item: ParsedInlineContent, font: NSFont, color: NSColor) -> NSAttributedString {
        switch item {
        case .text(let value):
            return NSAttributedString(string: value, attributes: [.font: font, .foregroundColor: color])
        case .bold(let content):
            return inline(content, font: ContentBlockRenderer.applyTraits(.bold, to: font), color: color)
        case .italic(let content):
            return inline(content, font: ContentBlockRenderer.applyTraits(.italic, to: font), color: color)
        case .link(let href, let content):
            let s = NSMutableAttributedString(attributedString: inline(content, font: font, color: accent))
            if let url = URL(string: href, relativeTo: URL(string: "https://archiveofourown.org")) {
                s.addAttribute(.link, value: url.absoluteURL, range: NSRange(location: 0, length: s.length))
            }
            return s
        case .strikethrough(let content):
            let s = NSMutableAttributedString(attributedString: inline(content, font: font, color: color))
            s.addAttribute(.strikethroughStyle, value: NSUnderlineStyle.single.rawValue,
                           range: NSRange(location: 0, length: s.length))
            return s
        case .superscript(let content):
            let s = NSMutableAttributedString(attributedString: inline(content, font: MacFont.ui(10), color: color))
            s.addAttribute(.baselineOffset, value: 4, range: NSRange(location: 0, length: s.length))
            return s
        case .lineBreak:
            return NSAttributedString(string: "\u{2028}", attributes: [.font: font])
        }
    }
}

/// Measures text exactly as `DiscussionBodyTextView` lays it out (TextKit 1,
/// no padding), off-screen — row heights never touch live views.
@MainActor
enum DiscussionMeasure {
    private static let storage = NSTextStorage()
    private static let layoutManager: NSLayoutManager = {
        let lm = NSLayoutManager()
        storage.addLayoutManager(lm)
        lm.addTextContainer(container)
        return lm
    }()
    private static let container: NSTextContainer = {
        let c = NSTextContainer(size: NSSize(width: 100, height: CGFloat.greatestFiniteMagnitude))
        c.lineFragmentPadding = 0
        return c
    }()

    static func height(_ text: NSAttributedString, width: CGFloat) -> CGFloat {
        guard text.length > 0, width > 0 else { return 0 }
        let lm = layoutManager
        container.size = NSSize(width: width, height: .greatestFiniteMagnitude)
        storage.setAttributedString(text)
        lm.ensureLayout(for: container)
        return ceil(lm.usedRect(for: container).height)
    }
}
