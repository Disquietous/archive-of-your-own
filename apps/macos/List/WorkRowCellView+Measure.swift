import AppKit

extension WorkRowCellView {
    static func ratingBadgeImage(for rating: Rating) -> NSImage {
        if let cached = badgeImages[rating] { return cached }
        let size = NSSize(width: badgeSize, height: badgeSize)
        let image = NSImage(size: size, flipped: false) { rect in
            NSColor(rating.badgeColor).setFill()
            NSBezierPath(roundedRect: rect, xRadius: 4, yRadius: 4).fill()
            let letter = NSAttributedString(string: rating.letter, attributes: [
                .font: MacFont.ui(9, weight: .heavy),
                .foregroundColor: NSColor.white,
            ])
            let s = letter.size()
            letter.draw(at: NSPoint(x: (rect.width - s.width) / 2, y: (rect.height - s.height) / 2))
            return true
        }
        badgeImages[rating] = image
        return image
    }

    /// Wraps the title so lines that share the vertical band of the top-right
    /// dates block stop short of it while every later line spans the full
    /// width. NSTextField can't vary width per line, so the wrap is computed
    /// with an exclusion-path layout and baked in as hard line breaks.
    /// Shared with BookmarkRowCellView, whose corner block is the
    /// bookmarked-by/date lines instead of the dates.
    static func wrappedAroundDates(_ title: NSAttributedString, width: CGFloat,
                                   datesSize: NSSize) -> NSAttributedString {
        // Keep at least 60pt of title width no matter how wide the dates run.
        let exclusionWidth = min(datesSize.width, width - 60)
        guard exclusionWidth > 0, datesSize.height > 0 else { return title }

        let storage = NSTextStorage(attributedString: title)
        let layoutManager = NSLayoutManager()
        let container = NSTextContainer(size: NSSize(width: width, height: .greatestFiniteMagnitude))
        container.lineFragmentPadding = 0
        container.exclusionPaths = [NSBezierPath(rect: NSRect(x: width - exclusionWidth, y: 0,
                                                              width: exclusionWidth,
                                                              height: datesSize.height))]
        layoutManager.addTextContainer(container)
        storage.addLayoutManager(layoutManager)
        layoutManager.ensureLayout(for: container)

        // Collect the character index ending each laid-out line.
        var breaks: [Int] = []
        var glyphIndex = 0
        while glyphIndex < layoutManager.numberOfGlyphs {
            var lineGlyphs = NSRange()
            layoutManager.lineFragmentRect(forGlyphAt: glyphIndex, effectiveRange: &lineGlyphs)
            let lineEnd = layoutManager.characterRange(forGlyphRange: lineGlyphs,
                                                       actualGlyphRange: nil).upperBound
            if lineEnd < storage.length { breaks.append(lineEnd) }
            glyphIndex = NSMaxRange(lineGlyphs)
        }
        guard !breaks.isEmpty else { return title }

        let wrapped = NSMutableAttributedString(attributedString: title)
        let text = title.string as NSString
        for lineEnd in breaks.reversed() {
            let before = text.character(at: lineEnd - 1)
            if before == 0x0A { continue }  // already a hard break
            let attributes = wrapped.attributes(at: lineEnd - 1, effectiveRange: nil)
            if before == 0x20 {
                // Soft wraps eat the boundary space; mirror that exactly.
                wrapped.replaceCharacters(in: NSRange(location: lineEnd - 1, length: 1),
                                          with: NSAttributedString(string: "\n", attributes: attributes))
            } else {
                wrapped.insert(NSAttributedString(string: "\n", attributes: attributes), at: lineEnd)
            }
        }
        return wrapped
    }

    /// Measure the summary's collapsed (2-line) and full heights at a width.
    static func summaryHeights(text: String, width: CGFloat) -> (collapsed: CGFloat, full: CGFloat) {
        let label = measureLabel
        label.font = MacFont.ui(12.5)
        label.stringValue = text
        label.preferredMaxLayoutWidth = width
        label.maximumNumberOfLines = 2
        let collapsed = label.intrinsicContentSize.height
        label.maximumNumberOfLines = 0
        label.invalidateIntrinsicContentSize()
        let full = label.intrinsicContentSize.height
        return (collapsed, max(full, collapsed))
    }

    /// Measure the tag pills' collapsed (2-line) and full heights at a width.
    static func tagsHeights(text: NSAttributedString, width: CGFloat) -> (collapsed: CGFloat, full: CGFloat) {
        let label = tagsMeasureLabel
        label.attributedStringValue = text
        label.preferredMaxLayoutWidth = width
        label.maximumNumberOfLines = 2
        label.invalidateIntrinsicContentSize()
        let collapsed = label.intrinsicContentSize.height
        label.maximumNumberOfLines = 0
        label.invalidateIntrinsicContentSize()
        let full = label.intrinsicContentSize.height
        return (collapsed, max(full, collapsed))
    }

    static func axDescription(for work: Work, progress: Double,
                              downloaded: Bool, bookmarked: Bool, finished: Bool) -> String {
        var parts: [String] = [work.title, "by \(work.author)"]
        if !work.fandomDisplay.isEmpty { parts.append(work.fandomDisplay) }
        parts.append("rated \(work.rating.rawValue)")
        parts.append("\(Fmt.k(work.words)) words")
        parts.append("\(work.chapterCount) of \(work.complete ? String(work.totalChapters) : "unknown") chapters")
        if progress > 0 { parts.append("\(Int((progress * 100).rounded())) percent read") }
        if downloaded { parts.append("available offline") }
        if bookmarked { parts.append("bookmarked") }
        if finished { parts.append("finished") }
        return parts.joined(separator: ", ")
    }
}
