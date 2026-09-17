import UIKit
import SwiftUI

/// Renders a ParsedContentBlock tree into an NSAttributedString for the
/// TextKit 2 reader — the UIKit twin of the macOS renderer. The two must
/// produce the SAME STRING for the same blocks and image state: the reading
/// position is a character offset into this string and travels between
/// devices through the synced library. Only paragraph styling may differ.
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
    var loadedImages: [String: UIImage] = [:]
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

    static func imageSrc(from url: URL) -> String? {
        guard url.scheme == imageLinkScheme,
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return nil }
        return components.queryItems?.first { $0.name == "src" }?.value
    }

    private var bodySize: CGFloat { CGFloat(theme.fontSize) }
    private var bodyFont: UIFont { Self.readingFont(named: theme.readingFont.fontName, size: bodySize) }
    private var inkColor: UIColor { UIColor(theme.ink) }
    private var ink2Color: UIColor { UIColor(theme.ink2) }
    private var ink3Color: UIColor { UIColor(theme.ink3) }
    private var accentColor: UIColor { UIColor(theme.accent) }

    // MARK: - Entry points

    /// The chapter body. `blockRanges` receives the range of every
    /// top-level block, in order, for the TTS highlight.
    func render(blocks: [ParsedContentBlock], blockRanges: inout [NSRange]) -> NSAttributedString {
        let result = NSMutableAttributedString()
        blockRanges.removeAll(keepingCapacity: true)
        for block in blocks {
            let start = result.length
            append(block, to: result, indentLevel: 0)
            blockRanges.append(NSRange(location: start, length: result.length - start))
        }
        return result
    }

    func render(blocks: [ParsedContentBlock]) -> NSAttributedString {
        var ranges: [NSRange] = []
        return render(blocks: blocks, blockRanges: &ranges)
    }

    /// The chapter header the reader stacks above each body: the
    /// "CH N OF M" line and the chapter title.
    func renderHeader(meta: String, title: String, leadingDivider: Bool) -> NSAttributedString {
        let result = NSMutableAttributedString()
        if leadingDivider {
            let style = NSMutableParagraphStyle()
            style.alignment = .center
            style.paragraphSpacingBefore = 32
            style.paragraphSpacing = 24
            result.append(NSAttributedString(
                string: "· · ·\n",
                attributes: [
                    .font: Self.uiFont(named: "Newsreader", size: 30, weight: .semibold),
                    .foregroundColor: ink3Color,
                    .paragraphStyle: style,
                ]))
        }
        let metaStyle = NSMutableParagraphStyle()
        metaStyle.paragraphSpacing = 4
        result.append(NSAttributedString(
            string: meta.uppercased() + "\n",
            attributes: [
                .font: Self.uiFont(named: "HankenGrotesk", size: 13, weight: .semibold),
                .foregroundColor: ink3Color,
                .kern: 0.3,
                .paragraphStyle: metaStyle,
            ]))
        let titleStyle = NSMutableParagraphStyle()
        titleStyle.paragraphSpacing = 8 + theme.readingLineSpacing
        result.append(NSAttributedString(
            string: title + "\n",
            attributes: [
                .font: Self.uiFont(named: "Newsreader", size: 26, weight: .semibold),
                .foregroundColor: inkColor,
                .paragraphStyle: titleStyle,
            ]))
        return result
    }

    /// A bundled (variable) UI font at `weight`, as SwiftUI's
    /// `.custom(name).weight()` resolves it; system font fallback.
    static func uiFont(named name: String, size: CGFloat, weight: UIFont.Weight) -> UIFont {
        guard let base = UIFont(name: name, size: size) else {
            return UIFont.systemFont(ofSize: size, weight: weight)
        }
        let descriptor = base.fontDescriptor.addingAttributes([
            .traits: [UIFontDescriptor.TraitKey.weight: weight]
        ])
        return UIFont(descriptor: descriptor, size: size)
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
            let lineColor = UIColor(theme.line)
            let image = UIGraphicsImageRenderer(size: CGSize(width: ruleWidth, height: 1)).image { context in
                lineColor.setFill()
                context.fill(CGRect(x: 0, y: 0, width: ruleWidth, height: 1))
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
                    .font: UIFont.monospacedSystemFont(ofSize: bodySize * 0.85, weight: .regular),
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
                .font: UIFont.systemFont(ofSize: bodySize * 0.8, weight: .medium),
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
                    .font: UIFont.systemFont(ofSize: bodySize * 0.72),
                    .foregroundColor: ink3Color,
                    .paragraphStyle: captionStyle,
                ]
            ))
        }
    }

    // MARK: - Inlines

    private func renderInlines(_ inlines: [ParsedInlineContent], baseFont: UIFont,
                               baseColor: UIColor) -> NSAttributedString {
        let result = NSMutableAttributedString()
        for inline in inlines {
            result.append(render(inline, font: baseFont, color: baseColor))
        }
        return result
    }

    private func render(_ inline: ParsedInlineContent, font: UIFont, color: UIColor) -> NSAttributedString {
        switch inline {
        case .text(let value):
            return NSAttributedString(string: value, attributes: [.font: font, .foregroundColor: color])

        case .bold(let content):
            let boldFont = Self.applyTraits(.traitBold, to: font)
            return mapChildren(content, font: boldFont, color: color)

        case .italic(let content):
            let italicFont = Self.applyTraits(.traitItalic, to: font)
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
            let smaller = UIFont(descriptor: font.fontDescriptor, size: font.pointSize * 0.7)
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

    private func mapChildren(_ content: [ParsedInlineContent], font: UIFont, color: UIColor) -> NSAttributedString {
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
    static func readingFont(named name: String, size: CGFloat, weight: UIFont.Weight = .regular) -> UIFont {
        if let font = UIFont(name: name, size: size) {
            if weight != .regular {
                return applyTraits(.traitBold, to: font)
            }
            return font
        }
        return serifFont(size: size, weight: weight)
    }

    static func serifFont(size: CGFloat, weight: UIFont.Weight = .regular) -> UIFont {
        let base = UIFont.systemFont(ofSize: size, weight: weight)
        if let descriptor = base.fontDescriptor.withDesign(.serif) {
            return UIFont(descriptor: descriptor, size: size)
        }
        return base
    }

    static func applyTraits(_ traits: UIFontDescriptor.SymbolicTraits, to font: UIFont) -> UIFont {
        guard let descriptor = font.fontDescriptor.withSymbolicTraits(font.fontDescriptor.symbolicTraits.union(traits)) else {
            return font
        }
        return UIFont(descriptor: descriptor, size: font.pointSize)
    }
}
