import AppKit
import SwiftUI

/// The small mark that says which site something came from. Template
/// images, so they take the color of the text beside them.
enum SourceBadge {
    /// Asset name for a source id: the assets are keyed by the id itself
    /// ("SourceBadge-ao3"), so a new source needs a new imageset and no
    /// code. nil for sample rows, which carry no source.
    static func imageName(for source: String) -> String? {
        source.isEmpty ? nil : "SourceBadge-\(source)"
    }

    static func image(for source: String) -> NSImage? {
        guard let name = imageName(for: source), let image = NSImage(named: name) else { return nil }
        image.isTemplate = true
        return image
    }

    /// The badge drawn in `color` at `height` points (width follows the
    /// mark's proportions) — for attributed strings, where a template
    /// image is not tinted for us.
    static func tinted(for source: String, color: NSColor, height: CGFloat) -> NSImage? {
        guard let base = image(for: source), base.size.height > 0 else { return nil }
        let size = NSSize(width: (height * base.size.width / base.size.height).rounded(), height: height)
        return NSImage(size: size, flipped: false) { rect in
            base.draw(in: rect)
            color.set()
            rect.fill(using: .sourceAtop)
            return true
        }
    }

    /// The badge as an inline run for a byline: "by [badge] Name". Sits on
    /// the baseline so its center lines up with the text's x-height.
    static func attachment(for source: String, font: NSFont, color: NSColor) -> NSAttributedString? {
        let height = (font.capHeight * 1.25).rounded()
        guard let image = tinted(for: source, color: color, height: height) else { return nil }
        let badge = NSTextAttachment()
        badge.image = image
        badge.bounds = CGRect(x: 0, y: (font.capHeight - height) / 2, width: image.size.width, height: height)
        return NSAttributedString(attachment: badge)
    }
}

/// Inline badge sized to sit beside a line of text.
struct SourceBadgeView: View {
    let source: String
    var size: CGFloat = 14

    var body: some View {
        if let name = SourceBadge.imageName(for: source) {
            Image(name)
                .renderingMode(.template)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(height: size)
        }
    }
}
