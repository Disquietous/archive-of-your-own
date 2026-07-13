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
    private let metaLabel = NSTextField(labelWithString: "")
    private let ratingBadge = NSTextField(labelWithString: "")
    private let progressTrack = NSView()
    private let progressFill = NSView()
    private var progressWidth: NSLayoutConstraint!

    private var isRowSelected = false
    /// Called when the user clicks a truncated summary to expand/collapse it.
    var onToggleSummary: (() -> Void)?

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
        summaryLabel.maximumNumberOfLines = 2
        summaryLabel.addGestureRecognizer(NSClickGestureRecognizer(target: self, action: #selector(summaryClicked)))
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

        let body = NSStackView(views: [fandomLabel, titleLabel, authorLabel, summaryLabel, metaLabel, progressTrack])
        body.orientation = .vertical
        body.alignment = .leading
        body.spacing = 3
        body.setCustomSpacing(2, after: fandomLabel)
        body.setCustomSpacing(6, after: authorLabel)
        body.setCustomSpacing(7, after: summaryLabel)
        body.setCustomSpacing(7, after: metaLabel)

        for view in [selectionBar, spine, body, ratingBadge] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        progressFill.translatesAutoresizingMaskIntoConstraints = false
        progressWidth = progressFill.widthAnchor.constraint(equalToConstant: 0)

        NSLayoutConstraint.activate([
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
            body.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -12),

            ratingBadge.topAnchor.constraint(equalTo: topAnchor, constant: 12),
            ratingBadge.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -14),
            ratingBadge.widthAnchor.constraint(equalToConstant: 18),
            ratingBadge.heightAnchor.constraint(equalToConstant: 18),

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

    func configure(with work: Work, progress: Double, downloaded: Bool, selected: Bool,
                   summaryExpanded: Bool, availableTextWidth: CGFloat) {
        isRowSelected = selected
        summaryLabel.maximumNumberOfLines = summaryExpanded ? 0 : 2
        // Wrapping labels need a known width to report correct heights for
        // automatic row sizing. Set it here, never in layout() — invalidating
        // intrinsic size during layout creates a feedback loop AppKit aborts on.
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
        summaryLabel.isHidden = work.summary.isEmpty

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
        fandomLabel.textColor = theme.nsAccent
        titleLabel.textColor = theme.nsInk
        summaryLabel.textColor = theme.nsInk2
        metaLabel.textColor = theme.nsInk3
        progressTrack.layer?.backgroundColor = theme.nsSurface3.cgColor
        progressFill.layer?.backgroundColor = theme.nsAccent.cgColor
    }
}
