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
        case .paragraph(let inlines):
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
            let style = NSMutableParagraphStyle()
            style.alignment = .center
            style.paragraphSpacingBefore = 14
            style.paragraphSpacing = 14
            result.append(NSAttributedString(
                string: "⁂\n",
                attributes: [
                    .font: bodyFont,
                    .foregroundColor: ink3Color,
                    .paragraphStyle: style,
                ]
            ))

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
