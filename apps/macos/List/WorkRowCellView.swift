import AppKit

/// One work row in the list pane, drawn per the handoff spec: fandom spine,
/// accent fandom label, serif title with inline rating badge, byline, 2-line
/// summary, meta row, published/updated dates in the top-right corner,
/// optional progress bar. Selection = accent-soft fill with a 3px accent bar
/// on the left edge.
final class WorkRowCellView: NSTableCellView {
    static let reuseID = NSUserInterfaceItemIdentifier("WorkRowCell")

    private let theme: AppTheme
    private let selectionBar = NSView()
    private let spine = NSView()
    private let fandomLabel = NSTextField(labelWithString: "")
    private let titleLabel = NSTextField(wrappingLabelWithString: "")
    private let authorLabel = NSTextField(labelWithString: "")
    private let summaryLabel = NSTextField(wrappingLabelWithString: "")
    /// Clipping container whose height constraint is what expand/collapse
    /// animates — a line-count clamp can't animate, a constraint can.
    private let summaryClip = NSView()
    private var summaryHeight: NSLayoutConstraint!
    private var collapsedSummaryHeight: CGFloat = 0
    private var fullSummaryHeight: CGFloat = 0
    private let tagsLabel = NSTextField(wrappingLabelWithString: "")
    /// Same clip-and-animate treatment as the summary: collapsed shows two
    /// rows of tag pills, clicking reveals the full set.
    private let tagsClip = NSView()
    private var tagsHeight: NSLayoutConstraint!
    private var collapsedTagsHeight: CGFloat = 0
    private var fullTagsHeight: CGFloat = 0
    private let metaLabel = NSTextField(labelWithString: "")
    private let datesLabel = NSTextField(labelWithString: "")
    private let progressTrack = NSView()
    private let progressFill = NSView()
    private var progressWidth: NSLayoutConstraint!
    /// Per-row bottom hairline (the design's row border) — the table grid is
    /// off because NSTableView paints phantom lines below the last row.
    private let separator = NSView()

    /// Density-driven metrics (Settings → Spacing). Updated in configure().
    private var bodyStack: NSStackView!
    private var bodyTop: NSLayoutConstraint!
    private var bodyBottom: NSLayoutConstraint!
    private var spineTop: NSLayoutConstraint!
    private var spineBottom: NSLayoutConstraint!
    private var datesTop: NSLayoutConstraint!

    private static func verticalPad(for density: Density) -> CGFloat {
        switch density {
        case .compact: 8
        case .regular: 12
        case .comfy: 17
        }
    }

    private static func sectionGap(for density: Density) -> CGFloat {
        switch density {
        case .compact: 5
        case .regular: 7
        case .comfy: 10
        }
    }

    private var isRowSelected = false
    /// Called when the user clicks a truncated summary to expand/collapse it.
    var onToggleSummary: (() -> Void)?
    /// Called when the user clicks the tags to expand/collapse the full list.
    var onToggleTags: (() -> Void)?

    /// Shared measuring label for summary heights.
    private static let measureLabel = NSTextField(wrappingLabelWithString: "")
    /// Separate measuring label for tags so attributed content never bleeds
    /// into the summary measurements.
    private static let tagsMeasureLabel = NSTextField(wrappingLabelWithString: "")

    init(theme: AppTheme) {
        self.theme = theme
        super.init(frame: .zero)
        wantsLayer = true

        selectionBar.wantsLayer = true
        spine.wantsLayer = true
        spine.layer?.cornerRadius = 1.5

        fandomLabel.font = MacFont.ui(11, weight: .bold)
        fandomLabel.lineBreakMode = .byTruncatingTail
        titleLabel.font = MacFont.serif(16, weight: .semibold)
        titleLabel.maximumNumberOfLines = 2
        authorLabel.font = MacFont.ui(12)
        authorLabel.lineBreakMode = .byTruncatingTail
        summaryLabel.font = MacFont.ui(12.5)
        summaryClip.wantsLayer = true
        summaryClip.layer?.masksToBounds = true
        summaryClip.addGestureRecognizer(NSClickGestureRecognizer(target: self, action: #selector(summaryClicked)))
        summaryLabel.translatesAutoresizingMaskIntoConstraints = false
        summaryClip.addSubview(summaryLabel)
        summaryHeight = summaryClip.heightAnchor.constraint(equalToConstant: 0)
        NSLayoutConstraint.activate([
            summaryHeight,
            summaryLabel.topAnchor.constraint(equalTo: summaryClip.topAnchor),
            summaryLabel.leadingAnchor.constraint(equalTo: summaryClip.leadingAnchor),
            summaryLabel.trailingAnchor.constraint(equalTo: summaryClip.trailingAnchor),
        ])
        tagsClip.wantsLayer = true
        tagsClip.layer?.masksToBounds = true
        tagsClip.addGestureRecognizer(NSClickGestureRecognizer(target: self, action: #selector(tagsClicked)))
        tagsLabel.translatesAutoresizingMaskIntoConstraints = false
        tagsClip.addSubview(tagsLabel)
        tagsHeight = tagsClip.heightAnchor.constraint(equalToConstant: 0)
        NSLayoutConstraint.activate([
            tagsHeight,
            tagsLabel.topAnchor.constraint(equalTo: tagsClip.topAnchor),
            tagsLabel.leadingAnchor.constraint(equalTo: tagsClip.leadingAnchor),
            tagsLabel.trailingAnchor.constraint(equalTo: tagsClip.trailingAnchor),
        ])
        metaLabel.font = MacFont.ui(11, weight: .medium)
        metaLabel.lineBreakMode = .byTruncatingTail

        datesLabel.font = MacFont.ui(10, weight: .medium)
        datesLabel.alignment = .right
        datesLabel.maximumNumberOfLines = 2

        progressTrack.wantsLayer = true
        progressTrack.layer?.cornerRadius = 1.5
        progressFill.wantsLayer = true
        progressFill.layer?.cornerRadius = 1.5
        progressTrack.addSubview(progressFill)

        let body = NSStackView(views: [fandomLabel, titleLabel, authorLabel, summaryClip, tagsClip, metaLabel, progressTrack])
        bodyStack = body
        body.orientation = .vertical
        body.alignment = .leading
        body.spacing = 3
        body.setCustomSpacing(2, after: fandomLabel)
        body.setCustomSpacing(6, after: authorLabel)
        body.setCustomSpacing(7, after: summaryClip)
        body.setCustomSpacing(7, after: tagsClip)
        body.setCustomSpacing(7, after: metaLabel)
        // Labels must refuse to be stretched past their intrinsic height —
        // otherwise row-height measurement is a one-way ratchet: a currently
        // tall (expanded) row satisfies its bottom pin by stretching the
        // labels, so a collapsed summary never measures shorter.
        for label in [fandomLabel, titleLabel, authorLabel, metaLabel] {
            label.setContentHuggingPriority(.init(751), for: .vertical)
        }

        separator.wantsLayer = true
        for view in [selectionBar, spine, body, datesLabel, separator] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        progressFill.translatesAutoresizingMaskIntoConstraints = false
        progressWidth = progressFill.widthAnchor.constraint(equalToConstant: 0)

        // High-but-not-required: during measurement it pulls the cell's bottom
        // snugly to the content (labels outrank it at 751, so nothing
        // stretches), and during the resize animation it degrades gracefully
        // instead of fighting the in-flight frame.
        bodyBottom = body.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -12)
        bodyBottom.priority = .defaultHigh
        bodyTop = body.topAnchor.constraint(equalTo: topAnchor, constant: 12)
        spineTop = spine.topAnchor.constraint(equalTo: topAnchor, constant: 12)
        spineBottom = spine.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -12)
        datesTop = datesLabel.topAnchor.constraint(equalTo: topAnchor, constant: 12)

        NSLayoutConstraint.activate([
            bodyBottom,
            separator.leadingAnchor.constraint(equalTo: leadingAnchor),
            separator.trailingAnchor.constraint(equalTo: trailingAnchor),
            separator.bottomAnchor.constraint(equalTo: bottomAnchor),
            separator.heightAnchor.constraint(equalToConstant: 1),
            selectionBar.leadingAnchor.constraint(equalTo: leadingAnchor),
            selectionBar.topAnchor.constraint(equalTo: topAnchor),
            selectionBar.bottomAnchor.constraint(equalTo: bottomAnchor),
            selectionBar.widthAnchor.constraint(equalToConstant: 3),

            spine.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
            spineTop,
            spineBottom,
            spine.widthAnchor.constraint(equalToConstant: 3),

            body.leadingAnchor.constraint(equalTo: spine.trailingAnchor, constant: 12),
            body.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -14),
            bodyTop,

            datesTop,
            datesLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -14),
            // The fandom line shares the dates' vertical band — cap it so a
            // long fandom truncates instead of running under the dates.
            fandomLabel.trailingAnchor.constraint(lessThanOrEqualTo: datesLabel.leadingAnchor, constant: -8),

            summaryClip.widthAnchor.constraint(equalTo: body.widthAnchor),
            tagsClip.widthAnchor.constraint(equalTo: body.widthAnchor),
            progressTrack.heightAnchor.constraint(equalToConstant: 3),
            progressTrack.widthAnchor.constraint(equalTo: body.widthAnchor),
            progressFill.leadingAnchor.constraint(equalTo: progressTrack.leadingAnchor),
            progressFill.topAnchor.constraint(equalTo: progressTrack.topAnchor),
            progressFill.bottomAnchor.constraint(equalTo: progressTrack.bottomAnchor),
            progressWidth,
        ])
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    @objc private func summaryClicked() {
        onToggleSummary?()
    }

    @objc private func tagsClicked() {
        onToggleTags?()
    }

    /// Animate only the summary reveal: the clip container's height constraint
    /// slides between the 2-line and full measurements. Call inside an
    /// NSAnimationContext with allowsImplicitAnimation for a smooth reveal.
    func setSummaryExpanded(_ expanded: Bool) {
        summaryHeight.constant = expanded ? fullSummaryHeight : collapsedSummaryHeight
    }

    /// Same animated reveal for the tags list.
    func setTagsExpanded(_ expanded: Bool) {
        tagsHeight.constant = expanded ? fullTagsHeight : collapsedTagsHeight
    }

    private static let badgeSize: CGFloat = 16

    /// Rounded-rect rating letter drawn as an image so it can ride inline at
    /// the end of the title as a text attachment. Cached per rating.
    private static var badgeImages: [Rating: NSImage] = [:]
    private static func ratingBadgeImage(for rating: Rating) -> NSImage {
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

    /// Measure the summary's collapsed (2-line) and full heights at a width.
    private static func summaryHeights(text: String, width: CGFloat) -> (collapsed: CGFloat, full: CGFloat) {
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
    private static func tagsHeights(text: NSAttributedString, width: CGFloat) -> (collapsed: CGFloat, full: CGFloat) {
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

    /// Flip only the selection highlight (background fill + accent bar) —
    /// no label content is touched.
    func setSelected(_ selected: Bool) {
        guard selected != isRowSelected else { return }
        isRowSelected = selected
        layer?.backgroundColor = selected ? theme.nsAccentSoft.cgColor : NSColor.clear.cgColor
        selectionBar.layer?.backgroundColor = selected ? theme.nsAccent.cgColor : NSColor.clear.cgColor
    }

    func configure(with work: Work, progress: Double, downloaded: Bool, selected: Bool,
                   summaryExpanded: Bool, tagsExpanded: Bool, availableTextWidth: CGFloat) {
        isRowSelected = selected
        // NSTextField caches its intrinsic size, and changing the line clamp
        // doesn't flush it — a reused cell going expanded → collapsed kept
        // measuring at full height. Invalidate exactly when the clamp changes
        // so the row re-measures symmetrically in both directions.
        // Wrapping labels need a known width to report correct heights for
        // row sizing. Set it here, never in layout() — invalidating intrinsic
        // size during layout creates a feedback loop AppKit aborts on.
        summaryLabel.preferredMaxLayoutWidth = availableTextWidth
        tagsLabel.preferredMaxLayoutWidth = availableTextWidth

        // Chrome fonts are assigned here, not in init, so the app text-size
        // setting (MacFont.scale) applies on every (re)configure.
        fandomLabel.font = MacFont.ui(11, weight: .bold)
        summaryLabel.font = MacFont.ui(12.5)
        metaLabel.font = MacFont.ui(11, weight: .medium)
        datesLabel.font = MacFont.ui(10, weight: .medium)

        // Density (Settings → Spacing) sets the row's breathing room.
        let vPad = Self.verticalPad(for: theme.density)
        let gap = Self.sectionGap(for: theme.density)
        bodyTop.constant = vPad
        bodyBottom.constant = -vPad
        spineTop.constant = vPad
        spineBottom.constant = -vPad
        datesTop.constant = vPad
        bodyStack.setCustomSpacing(gap, after: summaryClip)
        bodyStack.setCustomSpacing(gap, after: tagsClip)
        bodyStack.setCustomSpacing(gap, after: metaLabel)

        // Published/updated dates in the top-right corner. Blurb data only
        // carries an updated date; a work page carries both (identical for
        // single-chapter works — collapse to the published line then).
        var dateLines: [String] = []
        if !work.published.isEmpty { dateLines.append("Published \(work.published)") }
        if !work.updated.isEmpty && work.updated != work.published {
            dateLines.append("Updated \(work.updated)")
        }
        datesLabel.stringValue = dateLines.joined(separator: "\n")
        datesLabel.isHidden = dateLines.isEmpty
        // The title shares the dates' vertical band — wrap it short of them.
        let datesReserve = dateLines.isEmpty ? 0 : datesLabel.intrinsicContentSize.width + 8
        titleLabel.preferredMaxLayoutWidth = max(60, availableTextWidth - datesReserve)

        spine.layer?.backgroundColor = NSColor(work.spineColor).cgColor
        fandomLabel.stringValue = work.fandom

        // Serif title with the rating badge inline after the last word — a
        // non-breaking space keeps the badge from wrapping onto its own line.
        let titleFont = MacFont.serif(16, weight: .semibold)
        let title = NSMutableAttributedString(
            string: work.title + "\u{00A0}",
            attributes: [.font: titleFont, .foregroundColor: theme.nsInk])
        let badge = NSTextAttachment()
        badge.image = Self.ratingBadgeImage(for: work.rating)
        badge.bounds = CGRect(x: 0, y: (titleFont.capHeight - Self.badgeSize) / 2,
                              width: Self.badgeSize, height: Self.badgeSize)
        title.append(NSAttributedString(attachment: badge))
        titleLabel.attributedStringValue = title

        let author = NSMutableAttributedString(
            string: "by ", attributes: [.font: MacFont.ui(12), .foregroundColor: theme.nsInk3])
        author.append(NSAttributedString(
            string: work.author, attributes: [.font: MacFont.ui(12, weight: .semibold), .foregroundColor: theme.nsInk2]))
        authorLabel.attributedStringValue = author

        summaryLabel.stringValue = work.summary
        summaryClip.isHidden = work.summary.isEmpty

        tagsClip.isHidden = work.tags.isEmpty
        if !work.tags.isEmpty {
            let tags = NSMutableAttributedString()
            for (index, tag) in work.tags.enumerated() {
                if index > 0 {
                    tags.append(NSAttributedString(string: "  ", attributes: [.font: MacFont.ui(10.5)]))
                }
                tags.append(NSAttributedString(string: " \(tag) ", attributes: [
                    .font: MacFont.ui(10.5, weight: .semibold),
                    .foregroundColor: theme.nsInk2,
                    .backgroundColor: theme.nsSurface2,
                ]))
            }
            tagsLabel.attributedStringValue = tags
            let tagHeights = Self.tagsHeights(text: tags, width: availableTextWidth)
            collapsedTagsHeight = tagHeights.collapsed
            fullTagsHeight = tagHeights.full
            tagsHeight.constant = tagsExpanded ? fullTagsHeight : collapsedTagsHeight
        }
        let heights = Self.summaryHeights(text: work.summary, width: availableTextWidth)
        collapsedSummaryHeight = heights.collapsed
        fullSummaryHeight = heights.full
        summaryHeight.constant = summaryExpanded ? fullSummaryHeight : collapsedSummaryHeight

        var meta = "♥ \(Fmt.k(work.kudos))   \(Fmt.k(work.words)) words   \(work.chapterCount)/\(work.complete ? String(work.totalChapters) : "?")"
        if downloaded {
            meta += "   ⤓ Offline"
        }
        metaLabel.stringValue = meta

        progressTrack.isHidden = progress <= 0
        applyTheme()
        if progress > 0 {
            layoutSubtreeIfNeeded()
            progressWidth.constant = progressTrack.bounds.width * progress
        }
    }

    func applyTheme() {
        layer?.backgroundColor = isRowSelected ? theme.nsAccentSoft.cgColor : NSColor.clear.cgColor
        selectionBar.layer?.backgroundColor = isRowSelected ? theme.nsAccent.cgColor : NSColor.clear.cgColor
        separator.layer?.backgroundColor = theme.nsLine.cgColor
        fandomLabel.textColor = theme.nsAccent
        titleLabel.textColor = theme.nsInk
        summaryLabel.textColor = theme.nsInk2
        metaLabel.textColor = theme.nsInk3
        datesLabel.textColor = theme.nsInk3
        progressTrack.layer?.backgroundColor = theme.nsSurface3.cgColor
        progressFill.layer?.backgroundColor = theme.nsAccent.cgColor
    }
}
