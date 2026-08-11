import AppKit
import SwiftUI

/// Renders a ParsedContentBlock tree into an NSAttributedString for the
/// TextKit 2 reader. Second consumer of the same content tree the SwiftUI
/// views render on iOS — no HTML, no Rust changes.
struct ContentBlockRenderer {
    /// `.indented` — classic book style (first-line indent, no gaps).
    /// `.macReading` — the desktop handoff style (no indent, 1.2em paragraph gap).
    enum ParagraphMode {
        case indented, macReading
    }

    let theme: AppTheme
    var paragraphStyle: ParagraphMode = .indented
    /// Chapter-embedded images already fetched (src → image). Anything not
    /// here renders as a tap-to-load placeholder.
    var loadedImages: [String: NSImage] = [:]
    /// Per-image status overrides for the placeholder ("Loading…", errors).
    var imageStatus: [String: String] = [:]
    /// Display cap for image width; tall images scale proportionally.
    var imageDisplayWidth: CGFloat = 560

    /// Custom scheme carried in the placeholder's .link attribute; the
    /// reader's delegate intercepts it to trigger the fetch.
    static let imageLinkScheme = "aoyo-image"

    static func imageLinkURL(for src: String) -> URL? {
        var components = URLComponents()
        components.scheme = imageLinkScheme
        components.host = "load"
        components.queryItems = [URLQueryItem(name: "src", value: src)]
        return components.url
    }

    static func imageSrc(from link: Any) -> String? {
        let url: URL?
        if let u = link as? URL { url = u } else if let s = link as? String { url = URL(string: s) } else { url = nil }
        guard let url, url.scheme == imageLinkScheme,
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return nil }
        return components.queryItems?.first { $0.name == "src" }?.value
    }

    private var bodySize: CGFloat { CGFloat(theme.fontSize) }
    private var bodyFont: NSFont { Self.readingFont(named: theme.readingFont.fontName, size: bodySize) }
    private var inkColor: NSColor { NSColor(theme.ink) }
    private var ink2Color: NSColor { NSColor(theme.ink2) }
    private var ink3Color: NSColor { NSColor(theme.ink3) }
    private var accentColor: NSColor { NSColor(theme.accent) }

    // MARK: - Entry points

    func renderChapter(workTitle: String, author: String, chapterTitle: String,
                       blocks: [ParsedContentBlock]) -> NSAttributedString {
        let result = NSMutableAttributedString()

        let headerStyle = NSMutableParagraphStyle()
        headerStyle.paragraphSpacing = 4
        result.append(NSAttributedString(
            string: workTitle + "\n",
            attributes: [
                .font: Self.readingFont(named: theme.readingFont.fontName, size: 28, weight: .semibold),
                .foregroundColor: inkColor,
                .paragraphStyle: headerStyle,
            ]
        ))
        result.append(NSAttributedString(
            string: author + "\n",
            attributes: [
                .font: NSFont.systemFont(ofSize: 13),
                .foregroundColor: ink3Color,
                .paragraphStyle: headerStyle,
            ]
        ))
        let chapterStyle = NSMutableParagraphStyle()
        chapterStyle.paragraphSpacingBefore = 18
        chapterStyle.paragraphSpacing = 24
        result.append(NSAttributedString(
            string: chapterTitle + "\n",
            attributes: [
                .font: Self.readingFont(named: theme.readingFont.fontName, size: 20, weight: .semibold),
                .foregroundColor: inkColor,
                .paragraphStyle: chapterStyle,
            ]
        ))

        result.append(render(blocks: blocks))
        return result
    }

    func render(blocks: [ParsedContentBlock]) -> NSAttributedString {
        let result = NSMutableAttributedString()
        for block in blocks {
            append(block, to: result, indentLevel: 0)
        }
        return result
    }

    // MARK: - Blocks

    private func append(_ block: ParsedContentBlock, to result: NSMutableAttributedString, indentLevel: Int) {
        switch block {
        case .paragraph(let rawInlines):
            let inlines = Self.collapseDoubleBreaks(rawInlines)
            let text = renderInlines(inlines, baseFont: bodyFont, baseColor: inkColor)
            if text.string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                // Whitespace-only paragraphs are intentional blank space —
                // <p><br><br></p> scene breaks, <p>&nbsp;</p> spacers.
                // Render one empty line per <br> (at least one). Genuinely
                // empty <p></p> never gets here: the parser emits no block
                // for a paragraph with no inline content at all.
                let blankLines = max(Self.lineBreakCount(inlines), 1)
                let blanks = NSMutableAttributedString(
                    string: String(repeating: "\n", count: blankLines),
                    attributes: [.font: bodyFont, .foregroundColor: inkColor])
                applyParagraphStyle(bodyParagraphStyle(indentLevel: indentLevel), to: blanks)
                result.append(blanks)
                return
            }
            let mutable = NSMutableAttributedString(attributedString: text)
            mutable.append(NSAttributedString(string: "\n"))
            applyParagraphStyle(bodyParagraphStyle(indentLevel: indentLevel), to: mutable)
            result.append(mutable)

        case .heading(let level, let text):
            let size: CGFloat = switch level {
            case 1: bodySize * 1.45
            case 2: bodySize * 1.25
            case 3: bodySize * 1.1
            default: bodySize
            }
            let style = NSMutableParagraphStyle()
            style.paragraphSpacingBefore = level <= 2 ? 20 : 12
            style.paragraphSpacing = 8
            style.headIndent = CGFloat(indentLevel) * 24
            style.firstLineHeadIndent = CGFloat(indentLevel) * 24
            result.append(NSAttributedString(
                string: text + "\n",
                attributes: [
                    .font: Self.readingFont(named: theme.readingFont.fontName, size: size, weight: .semibold),
                    .foregroundColor: inkColor,
                    .paragraphStyle: style,
                ]
            ))

        case .blockquote(let blocks):
            for inner in blocks {
                let start = result.length
                append(inner, to: result, indentLevel: indentLevel + 1)
                // Tint quoted text toward the secondary ink color.
                result.addAttribute(.foregroundColor, value: ink2Color,
                                    range: NSRange(location: start, length: result.length - start))
            }

        case .horizontalRule:
            // An actual drawn rule (like HTML <hr>), centered at the full
            // text measure, via a 1pt-high tinted attachment image.
            let style = NSMutableParagraphStyle()
            style.alignment = .center
            style.paragraphSpacingBefore = 14
            style.paragraphSpacing = 14
            let ruleWidth = max(120, imageDisplayWidth)
            let lineColor = NSColor(theme.line)
            let image = NSImage(size: NSSize(width: ruleWidth, height: 1), flipped: false) { rect in
                lineColor.setFill()
                rect.fill()
                return true
            }
            let attachment = NSTextAttachment()
            attachment.image = image
            attachment.bounds = CGRect(x: 0, y: bodySize * 0.22, width: ruleWidth, height: 1)
            let rule = NSMutableAttributedString(attachment: attachment)
            rule.append(NSAttributedString(string: "\n"))
            rule.addAttributes([.paragraphStyle: style],
                               range: NSRange(location: 0, length: rule.length))
            result.append(rule)

        case .list(let ordered, let items):
            for (index, itemBlocks) in items.enumerated() {
                let marker = ordered ? "\(index + 1)." : "•"
                let markerString = NSMutableAttributedString(
                    string: marker + "\t",
                    attributes: [.font: bodyFont, .foregroundColor: ink3Color]
                )
                let start = result.length
                result.append(markerString)
                var first = true
                for inner in itemBlocks {
                    append(inner, to: result, indentLevel: first ? 0 : indentLevel + 1)
                    first = false
                }
                let style = bodyParagraphStyle(indentLevel: indentLevel)
                style.headIndent = CGFloat(indentLevel + 1) * 28
                style.firstLineHeadIndent = CGFloat(indentLevel) * 28
                style.tabStops = [NSTextTab(textAlignment: .left, location: CGFloat(indentLevel + 1) * 28)]
                style.paragraphSpacing = 4
                result.addAttribute(.paragraphStyle, value: style,
                                    range: NSRange(location: start, length: result.length - start))
            }

        case .preFormatted(let text):
            let style = NSMutableParagraphStyle()
            style.paragraphSpacingBefore = 10
            style.paragraphSpacing = 10
            style.headIndent = 16
            style.firstLineHeadIndent = 16
            result.append(NSAttributedString(
                string: text + "\n",
                attributes: [
                    .font: NSFont.monospacedSystemFont(ofSize: bodySize * 0.85, weight: .regular),
                    .foregroundColor: ink2Color,
                    .paragraphStyle: style,
                ]
            ))

        case .image(let src, let alt):
            appendImage(src: src, alt: alt, to: result)
        }
    }

    /// A loaded image as a centered attachment (scaled to the column) with an
    /// alt-text caption; otherwise a tap-to-load placeholder line whose .link
    /// carries the source URL for the reader's delegate.
    private func appendImage(src: String, alt: String, to result: NSMutableAttributedString) {
        let style = NSMutableParagraphStyle()
        style.alignment = .center
        style.paragraphSpacingBefore = 12
        style.paragraphSpacing = 4

        if let image = loadedImages[src] {
            let attachment = NSTextAttachment()
            attachment.image = image
            let size = image.size
            let scale = size.width > imageDisplayWidth && size.width > 0
                ? imageDisplayWidth / size.width : 1
            attachment.bounds = CGRect(x: 0, y: 0,
                                       width: size.width * scale, height: size.height * scale)
            let line = NSMutableAttributedString(attachment: attachment)
            line.append(NSAttributedString(string: "\n"))
            line.addAttributes([.paragraphStyle: style],
                               range: NSRange(location: 0, length: line.length))
            result.append(line)
        } else {
            let label: String
            if let status = imageStatus[src] {
                label = status
            } else if alt.isEmpty {
                label = "Tap to load image"
            } else {
                label = "Tap to load image — \(alt)"
            }
            var attributes: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: bodySize * 0.8, weight: .medium),
                .foregroundColor: accentColor,
                .paragraphStyle: style,
            ]
            if let link = Self.imageLinkURL(for: src) {
                attributes[.link] = link
                // Suppress the default link underline/color pair fighting the
                // accent styling.
                attributes[.underlineStyle] = NSUnderlineStyle.single.rawValue
            }
            result.append(NSAttributedString(string: "🖼 \(label)\n", attributes: attributes))
        }

        // Caption under a loaded image only — the placeholder already
        // carries the alt text.
        if loadedImages[src] != nil, !alt.isEmpty {
            let captionStyle = NSMutableParagraphStyle()
            captionStyle.alignment = .center
            captionStyle.paragraphSpacing = 12
            result.append(NSAttributedString(
                string: alt + "\n",
                attributes: [
                    .font: NSFont.systemFont(ofSize: bodySize * 0.72),
                    .foregroundColor: ink3Color,
                    .paragraphStyle: captionStyle,
                ]
            ))
        }
    }

    // MARK: - Inlines

    private func renderInlines(_ inlines: [ParsedInlineContent], baseFont: NSFont,
                               baseColor: NSColor) -> NSAttributedString {
        let result = NSMutableAttributedString()
        for inline in inlines {
            result.append(render(inline, font: baseFont, color: baseColor))
        }
        return result
    }

    private func render(_ inline: ParsedInlineContent, font: NSFont, color: NSColor) -> NSAttributedString {
        switch inline {
        case .text(let value):
            return NSAttributedString(string: value, attributes: [.font: font, .foregroundColor: color])

        case .bold(let content):
            let boldFont = Self.applyTraits(.bold, to: font)
            return mapChildren(content, font: boldFont, color: color)

        case .italic(let content):
            let italicFont = Self.applyTraits(.italic, to: font)
            return mapChildren(content, font: italicFont, color: color)

        case .link(let href, let content):
            let rendered = NSMutableAttributedString(attributedString: mapChildren(content, font: font, color: accentColor))
            if let url = URL(string: href) {
                rendered.addAttribute(.link, value: url, range: NSRange(location: 0, length: rendered.length))
            }
            return rendered

        case .strikethrough(let content):
            let rendered = NSMutableAttributedString(attributedString: mapChildren(content, font: font, color: color))
            rendered.addAttribute(.strikethroughStyle, value: NSUnderlineStyle.single.rawValue,
                                  range: NSRange(location: 0, length: rendered.length))
            return rendered

        case .superscript(let content):
            let smaller = NSFont(descriptor: font.fontDescriptor, size: font.pointSize * 0.7) ?? font
            let rendered = NSMutableAttributedString(attributedString: mapChildren(content, font: smaller, color: color))
            rendered.addAttribute(.baselineOffset, value: font.pointSize * 0.33,
                                  range: NSRange(location: 0, length: rendered.length))
            return rendered

        case .lineBreak:
            return NSAttributedString(string: "\n", attributes: [.font: font, .foregroundColor: color])
        }
    }

    /// AO3 authors separate lines with <br><br>; a browser shows that as a
    /// single blank line. Rendered naively each "\n" ends an attributed-string
    /// paragraph and collects paragraphSpacing, so a pair reads as two blank
    /// lines. Replace each run of 2+ breaks (whitespace-only text between
    /// them is invisible) with a paragraph end plus a U+2028 line separator —
    /// the following line starts blank, so the gap is exactly one empty line.
    private static func collapseDoubleBreaks(_ inlines: [ParsedInlineContent]) -> [ParsedInlineContent] {
        var out: [ParsedInlineContent] = []
        var i = 0
        while i < inlines.count {
            guard case .lineBreak = inlines[i] else {
                out.append(inlines[i])
                i += 1
                continue
            }
            var breaks = 1
            var lastBreak = i
            var j = i + 1
            scan: while j < inlines.count {
                switch inlines[j] {
                case .lineBreak:
                    breaks += 1
                    lastBreak = j
                    j += 1
                case .text(let value) where value.trimmingCharacters(in: .whitespaces).isEmpty:
                    j += 1
                default:
                    break scan
                }
            }
            out.append(.lineBreak)
            if breaks >= 2 {
                out.append(.text(value: "\u{2028}"))
            }
            i = lastBreak + 1
        }
        return out
    }

    /// Recursive count of explicit line breaks in an inline tree.
    private static func lineBreakCount(_ inlines: [ParsedInlineContent]) -> Int {
        inlines.reduce(0) { total, inline in
            switch inline {
            case .lineBreak:
                total + 1
            case .bold(let content), .italic(let content), .strikethrough(let content),
                 .superscript(let content), .link(_, let content):
                total + lineBreakCount(content)
            case .text:
                total
            }
        }
    }

    private func mapChildren(_ content: [ParsedInlineContent], font: NSFont, color: NSColor) -> NSAttributedString {
        let result = NSMutableAttributedString()
        for child in content {
            result.append(render(child, font: font, color: color))
        }
        return result
    }

    // MARK: - Styles & fonts

    private func bodyParagraphStyle(indentLevel: Int) -> NSMutableParagraphStyle {
        let style = NSMutableParagraphStyle()
        style.lineHeightMultiple = theme.readLeading
        style.hyphenationFactor = theme.readHyphenation ? 0.9 : 0
        if theme.readJustified {
            style.alignment = .justified
        }
        style.headIndent = CGFloat(indentLevel) * 24
        switch paragraphStyle {
        case .indented:
            style.paragraphSpacing = bodySize * 0.6
            style.firstLineHeadIndent = CGFloat(indentLevel) * 24 + (indentLevel == 0 ? bodySize * 1.5 : 0)
        case .macReading:
            style.paragraphSpacing = bodySize * 1.2
            style.firstLineHeadIndent = CGFloat(indentLevel) * 24
        }
        return style
    }

    private func applyParagraphStyle(_ style: NSParagraphStyle, to text: NSMutableAttributedString) {
        text.addAttribute(.paragraphStyle, value: style, range: NSRange(location: 0, length: text.length))
    }

    /// Theme reading font by PostScript/family name, falling back to the system serif design.
    static func readingFont(named name: String, size: CGFloat, weight: NSFont.Weight = .regular) -> NSFont {
        if let font = NSFont(name: name, size: size) {
            if weight != .regular {
                return applyTraits(.bold, to: font)
            }
            return font
        }
        return serifFont(size: size, weight: weight)
    }

    static func serifFont(size: CGFloat, weight: NSFont.Weight = .regular) -> NSFont {
        let base = NSFont.systemFont(ofSize: size, weight: weight)
        if let descriptor = base.fontDescriptor.withDesign(.serif),
           let font = NSFont(descriptor: descriptor, size: size) {
            return font
        }
        return base
    }

    static func applyTraits(_ traits: NSFontDescriptor.SymbolicTraits, to font: NSFont) -> NSFont {
        let descriptor = font.fontDescriptor.withSymbolicTraits(font.fontDescriptor.symbolicTraits.union(traits))
        return NSFont(descriptor: descriptor, size: font.pointSize) ?? font
    }
}
