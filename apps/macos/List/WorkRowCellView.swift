import AppKit

/// One work row in the list pane, drawn per the handoff spec: fandom spine,
/// accent fandom label, serif title, byline, 2-line summary, meta row,
/// rating badge, optional progress bar. Selection = accent-soft fill with a
/// 3px accent bar on the left edge.
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
    private let metaLabel = NSTextField(labelWithString: "")
    private let ratingBadge = NSTextField(labelWithString: "")
    private let progressTrack = NSView()
    private let progressFill = NSView()
    private var progressWidth: NSLayoutConstraint!
    /// Per-row bottom hairline (the design's row border) — the table grid is
    /// off because NSTableView paints phantom lines below the last row.
    private let separator = NSView()

    private var isRowSelected = false
    /// Called when the user clicks a truncated summary to expand/collapse it.
    var onToggleSummary: (() -> Void)?

    /// Shared measuring label for summary heights.
    private static let measureLabel = NSTextField(wrappingLabelWithString: "")

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
        metaLabel.font = MacFont.ui(11, weight: .medium)
        metaLabel.lineBreakMode = .byTruncatingTail

        ratingBadge.font = MacFont.ui(10, weight: .heavy)
        ratingBadge.alignment = .center
        ratingBadge.wantsLayer = true
        ratingBadge.layer?.cornerRadius = 5
        ratingBadge.textColor = .white

        progressTrack.wantsLayer = true
        progressTrack.layer?.cornerRadius = 1.5
        progressFill.wantsLayer = true
        progressFill.layer?.cornerRadius = 1.5
        progressTrack.addSubview(progressFill)

        let body = NSStackView(views: [fandomLabel, titleLabel, authorLabel, summaryClip, metaLabel, progressTrack])
        body.orientation = .vertical
        body.alignment = .leading
        body.spacing = 3
        body.setCustomSpacing(2, after: fandomLabel)
        body.setCustomSpacing(6, after: authorLabel)
        body.setCustomSpacing(7, after: summaryClip)
        body.setCustomSpacing(7, after: metaLabel)
        // Labels must refuse to be stretched past their intrinsic height —
        // otherwise row-height measurement is a one-way ratchet: a currently
        // tall (expanded) row satisfies its bottom pin by stretching the
        // labels, so a collapsed summary never measures shorter.
        for label in [fandomLabel, titleLabel, authorLabel, metaLabel] {
            label.setContentHuggingPriority(.init(751), for: .vertical)
        }

        separator.wantsLayer = true
        for view in [selectionBar, spine, body, ratingBadge, separator] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        progressFill.translatesAutoresizingMaskIntoConstraints = false
        progressWidth = progressFill.widthAnchor.constraint(equalToConstant: 0)

        // High-but-not-required: during measurement it pulls the cell's bottom
        // snugly to the content (labels outrank it at 751, so nothing
        // stretches), and during the resize animation it degrades gracefully
        // instead of fighting the in-flight frame.
        let bodyBottom = body.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -12)
        bodyBottom.priority = .defaultHigh

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
            spine.topAnchor.constraint(equalTo: topAnchor, constant: 12),
            spine.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -12),
            spine.widthAnchor.constraint(equalToConstant: 3),

            body.leadingAnchor.constraint(equalTo: spine.trailingAnchor, constant: 12),
            body.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -40),
            body.topAnchor.constraint(equalTo: topAnchor, constant: 12),

            ratingBadge.topAnchor.constraint(equalTo: topAnchor, constant: 12),
            ratingBadge.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -14),
            ratingBadge.widthAnchor.constraint(equalToConstant: 18),
            ratingBadge.heightAnchor.constraint(equalToConstant: 18),

            summaryClip.widthAnchor.constraint(equalTo: body.widthAnchor),
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

    /// Animate only the summary reveal: the clip container's height constraint
    /// slides between the 2-line and full measurements. Call inside an
    /// NSAnimationContext with allowsImplicitAnimation for a smooth reveal.
    func setSummaryExpanded(_ expanded: Bool) {
        summaryHeight.constant = expanded ? fullSummaryHeight : collapsedSummaryHeight
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

    /// Flip only the selection highlight (background fill + accent bar) —
    /// no label content is touched.
    func setSelected(_ selected: Bool) {
        guard selected != isRowSelected else { return }
        isRowSelected = selected
        layer?.backgroundColor = selected ? theme.nsAccentSoft.cgColor : NSColor.clear.cgColor
        selectionBar.layer?.backgroundColor = selected ? theme.nsAccent.cgColor : NSColor.clear.cgColor
    }

    func configure(with work: Work, progress: Double, downloaded: Bool, selected: Bool,
                   summaryExpanded: Bool, availableTextWidth: CGFloat) {
        isRowSelected = selected
        // NSTextField caches its intrinsic size, and changing the line clamp
        // doesn't flush it — a reused cell going expanded → collapsed kept
        // measuring at full height. Invalidate exactly when the clamp changes
        // so the row re-measures symmetrically in both directions.
        // Wrapping labels need a known width to report correct heights for
        // row sizing. Set it here, never in layout() — invalidating intrinsic
        // size during layout creates a feedback loop AppKit aborts on.
        titleLabel.preferredMaxLayoutWidth = availableTextWidth
        summaryLabel.preferredMaxLayoutWidth = availableTextWidth

        spine.layer?.backgroundColor = NSColor(work.spineColor).cgColor
        fandomLabel.stringValue = work.fandom
        titleLabel.stringValue = work.title

        let author = NSMutableAttributedString(
            string: "by ", attributes: [.font: MacFont.ui(12), .foregroundColor: theme.nsInk3])
        author.append(NSAttributedString(
            string: work.author, attributes: [.font: MacFont.ui(12, weight: .semibold), .foregroundColor: theme.nsInk2]))
        authorLabel.attributedStringValue = author

        summaryLabel.stringValue = work.summary
        summaryClip.isHidden = work.summary.isEmpty
        let heights = Self.summaryHeights(text: work.summary, width: availableTextWidth)
        collapsedSummaryHeight = heights.collapsed
        fullSummaryHeight = heights.full
        summaryHeight.constant = summaryExpanded ? fullSummaryHeight : collapsedSummaryHeight

        var meta = "♥ \(Fmt.k(work.kudos))   \(Fmt.k(work.words)) words   \(work.chapterCount)/\(work.complete ? String(work.totalChapters) : "?")"
        if downloaded {
            meta += "   ⤓ Offline"
        }
        metaLabel.stringValue = meta

        ratingBadge.stringValue = work.rating.letter
        ratingBadge.layer?.backgroundColor = NSColor(work.rating.badgeColor).cgColor

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
        progressTrack.layer?.backgroundColor = theme.nsSurface3.cgColor
        progressFill.layer?.backgroundColor = theme.nsAccent.cgColor
    }
}
