import AppKit

/// The follow bell used in list-item bylines and headers: filled + accent
/// while the target is followed (or subscribed on AO3). Clicking opens the
/// Followed / Subscribed menu (FollowBellMenu) — the owner wires `onClick`.
/// Shared by WorkRowCellView, BookmarkRowCellView and the SwiftUI FollowBell.
final class FollowBellButton: NSButton {
    let theme: AppTheme
    private let pointSize: CGFloat
    private(set) var name: String = ""
    var onClick: ((FollowBellButton) -> Void)?

    init(theme: AppTheme, pointSize: CGFloat = 11) {
        self.theme = theme
        self.pointSize = pointSize
        super.init(frame: .zero)
        isBordered = false
        setButtonType(.momentaryPushIn)
        target = self
        action = #selector(clicked)
        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: pointSize + 7),
            heightAnchor.constraint(equalToConstant: pointSize + 7),
        ])
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    @objc private func clicked() {
        onClick?(self)
    }

    func configure(name: String, shaded: Bool) {
        self.name = name
        image = NSImage(systemSymbolName: shaded ? "bell.fill" : "bell",
                        accessibilityDescription: "Follow options for \(name)")?
            .withSymbolConfiguration(.init(pointSize: pointSize, weight: .medium))
        contentTintColor = shaded ? theme.nsAccent : theme.nsInk3
        toolTip = "Followed / Subscribed — choose how to track \(name)"
    }
}

/// One work row in the list pane, drawn per the handoff spec: fandom spine,
/// accent fandom label, serif title with inline rating badge, byline, 2-line
/// summary, meta row, published/updated dates in the top-right corner,
/// optional progress bar. Selection = accent-soft fill with a 3px accent bar
/// on the left edge.
final class WorkRowCellView: NSTableCellView {
    static let reuseID = NSUserInterfaceItemIdentifier("WorkRowCell")

    let theme: AppTheme
    let selectionBar = NSView()
    private let spine = NSView()
    let fandomLabel = NSTextField(wrappingLabelWithString: "")
    let titleLabel = NSTextField(wrappingLabelWithString: "")
    private let authorLabel = NSTextField(labelWithString: "")
    let summaryLabel = NSTextField(wrappingLabelWithString: "")
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
    let metaLabel = NSTextField(labelWithString: "")
    let datesLabel = NSTextField(labelWithString: "")
    /// "New" pill in the top-right corner: a What's New entry the user has
    /// not selected since it was added. Hidden everywhere else.
    let newBadge = NSTextField(labelWithString: "NEW")
    private var isNew = false
    /// "Removed" pill beside the "New" pill: the work is flagged
    /// `gone_from_ao3` (deleted or hidden on AO3; only the cached copy remains).
    let removedBadge = NSTextField(labelWithString: "REMOVED")
    private var isRemoved = false
    /// Holds both pills; a hidden pill detaches so the other slides over.
    private let badgeStack = NSStackView()
    let progressTrack = NSView()
    let progressFill = NSView()
    private var progressWidth: NSLayoutConstraint!
    /// Per-row bottom hairline (the design's row border) — the table grid is
    /// off because NSTableView paints phantom lines below the last row.
    let separator = NSView()
    /// Quick bookmark toggle, aligned with the meta row — bookmark a work
    /// straight from the list without opening its detail page.
    private let bookmarkButton = NSButton()
    private var isBookmarked = false
    /// Byline follow bell (the work detail byline's control) plus the
    /// clickable author name that opens the author profile.
    private let followButton: FollowBellButton
    private var bylineRow: NSStackView!
    private var authorName = ""

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

    var isRowSelected = false
    /// Called when the user clicks a truncated summary to expand/collapse it.
    var onToggleSummary: (() -> Void)?
    /// Called when the user clicks the row's bookmark button.
    var onToggleBookmark: (() -> Void)?
    /// Called when the user clicks the tags to expand/collapse the full list.
    var onToggleTags: (() -> Void)?
    /// Called when the user clicks the byline — opens the author profile.
    var onAuthorClick: (() -> Void)?
    /// Called when the user clicks the byline's follow bell.
    /// The byline bell was clicked — the owner pops the bell menu from it.
    var onFollowBell: ((NSView) -> Void)?

    /// Shared measuring label for summary heights.
    static let measureLabel = NSTextField(wrappingLabelWithString: "")
    /// Separate measuring label for tags so attributed content never bleeds
    /// into the summary measurements.
    static let tagsMeasureLabel = NSTextField(wrappingLabelWithString: "")

    init(theme: AppTheme) {
        self.theme = theme
        self.followButton = FollowBellButton(theme: theme)
        super.init(frame: .zero)
        wantsLayer = true

        selectionBar.wantsLayer = true
        spine.wantsLayer = true
        spine.layer?.cornerRadius = 1.5

        fandomLabel.font = MacFont.ui(11, weight: .bold)
        fandomLabel.maximumNumberOfLines = 0
        fandomLabel.isSelectable = false
        titleLabel.font = MacFont.serif(16, weight: .semibold)
        titleLabel.maximumNumberOfLines = 0
        // Wrapping labels are selectable by default — a selectable title
        // consumes row clicks (blocking selection) and hands the text to the
        // field editor, which drops the inline rating-badge attachment.
        titleLabel.isSelectable = false
        let byline = makeByline()
        configureSummaryAndTagsClips()
        configureChrome()

        let body = makeBodyStack(byline: byline)

        bookmarkButton.isBordered = false
        bookmarkButton.setButtonType(.momentaryPushIn)
        bookmarkButton.target = self
        bookmarkButton.action = #selector(bookmarkClicked)
        bookmarkButton.toolTip = "Bookmark"

        separator.wantsLayer = true
        badgeStack.orientation = .horizontal
        badgeStack.spacing = 6
        badgeStack.addArrangedSubview(removedBadge)
        badgeStack.addArrangedSubview(newBadge)
        for view in [selectionBar, spine, body, datesLabel, badgeStack, separator, bookmarkButton] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        progressFill.translatesAutoresizingMaskIntoConstraints = false
        progressWidth = progressFill.widthAnchor.constraint(equalToConstant: 0)

        activateRowConstraints(body: body)
    }

    private func makeByline() -> NSStackView {
        authorLabel.font = MacFont.ui(12)
        authorLabel.lineBreakMode = .byTruncatingTail
        authorLabel.addGestureRecognizer(NSClickGestureRecognizer(target: self, action: #selector(authorClicked)))
        followButton.onClick = { [weak self] bell in self?.onFollowBell?(bell) }
        let byline = NSStackView(views: [authorLabel, followButton])
        bylineRow = byline
        byline.orientation = .horizontal
        byline.alignment = .centerY
        byline.spacing = 4
        return byline
    }

    private func configureSummaryAndTagsClips() {
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
    }

    private func configureChrome() {
        metaLabel.font = MacFont.ui(11, weight: .medium)
        metaLabel.lineBreakMode = .byTruncatingTail

        datesLabel.font = MacFont.ui(10, weight: .medium)
        datesLabel.alignment = .right
        datesLabel.maximumNumberOfLines = 2

        newBadge.wantsLayer = true
        newBadge.layer?.cornerRadius = 4
        newBadge.alignment = .center
        newBadge.isHidden = true

        removedBadge.wantsLayer = true
        removedBadge.layer?.cornerRadius = 4
        removedBadge.alignment = .center
        removedBadge.isHidden = true

        progressTrack.wantsLayer = true
        progressTrack.layer?.cornerRadius = 1.5
        progressFill.wantsLayer = true
        progressFill.layer?.cornerRadius = 1.5
        progressTrack.addSubview(progressFill)
    }

    private func makeBodyStack(byline: NSStackView) -> NSStackView {
        let body = NSStackView(views: [titleLabel, byline, fandomLabel, summaryClip, tagsClip, metaLabel, progressTrack])
        bodyStack = body
        body.orientation = .vertical
        body.alignment = .leading
        body.spacing = 3
        body.setCustomSpacing(2, after: byline)
        body.setCustomSpacing(6, after: fandomLabel)
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
        return body
    }

    private func activateRowConstraints(body: NSStackView) {
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
            // Pills sit left of the dates block, on the dates' first line.
            badgeStack.trailingAnchor.constraint(equalTo: datesLabel.leadingAnchor, constant: -8),
            badgeStack.centerYAnchor.constraint(equalTo: datesLabel.firstBaselineAnchor, constant: -3),
            newBadge.widthAnchor.constraint(equalToConstant: 36),
            newBadge.heightAnchor.constraint(equalToConstant: 16),
            removedBadge.widthAnchor.constraint(equalToConstant: 58),
            removedBadge.heightAnchor.constraint(equalToConstant: 16),
            fandomLabel.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -14),

            bookmarkButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            bookmarkButton.centerYAnchor.constraint(equalTo: metaLabel.centerYAnchor),
            bookmarkButton.widthAnchor.constraint(equalToConstant: 24),
            bookmarkButton.heightAnchor.constraint(equalToConstant: 24),

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

    @objc private func bookmarkClicked() {
        onToggleBookmark?()
    }

    @objc private func authorClicked() {
        onAuthorClick?()
    }

    /// Flip only the byline bell — callable without reconfiguring so follow
    /// toggles reflect instantly on every visible row.
    func setFollowShaded(_ shaded: Bool) {
        followButton.configure(name: authorName, shaded: shaded)
    }

    /// Flip only the bookmark indicator — callable without reconfiguring so
    /// toggles reflect instantly on every visible row.
    /// What's New "New" pill — shown until the entry is selected.
    func setNew(_ new: Bool) {
        isNew = new
        newBadge.isHidden = !new
    }

    /// "Removed" pill — the work's `gone_from_ao3` flag.
    func setRemoved(_ removed: Bool) {
        isRemoved = removed
        removedBadge.isHidden = !removed
    }

    func setBookmarked(_ bookmarked: Bool) {
        isBookmarked = bookmarked
        bookmarkButton.image = NSImage(systemSymbolName: bookmarked ? "bookmark.fill" : "bookmark",
                                       accessibilityDescription: bookmarked ? "Remove bookmark" : "Bookmark")?
            .withSymbolConfiguration(.init(pointSize: 12, weight: .medium))
        bookmarkButton.contentTintColor = bookmarked ? theme.nsAccent : theme.nsInk3
        bookmarkButton.toolTip = bookmarked ? "Remove bookmark" : "Bookmark"
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

    static let badgeSize: CGFloat = 16

    /// Rounded-rect rating letter drawn as an image so it can ride inline at
    /// the end of the title as a text attachment. Cached per rating. Shared
    /// with BookmarkRowCellView so every row's badge is pixel-identical.
    static var badgeImages: [Rating: NSImage] = [:]

    /// Flip only the selection highlight (background fill + accent bar) —
    /// no label content is touched.
    func setSelected(_ selected: Bool) {
        guard selected != isRowSelected else { return }
        isRowSelected = selected
        layer?.backgroundColor = selected ? theme.nsAccentSoft.cgColor : NSColor.clear.cgColor
        selectionBar.layer?.backgroundColor = selected ? theme.nsAccent.cgColor : NSColor.clear.cgColor
    }

    func configure(with work: Work, progress: Double, downloaded: Bool, selected: Bool,
                   bookmarked: Bool = false, kudosGiven: Bool = false,
                   followShaded: Bool = false,
                   isNew: Bool = false, isRemoved: Bool = false, finished: Bool = false,
                   summaryExpanded: Bool, tagsExpanded: Bool, availableTextWidth: CGFloat) {
        setBookmarked(bookmarked)
        self.kudosGiven = kudosGiven
        self.finished = finished
        setNew(isNew)
        setRemoved(isRemoved)
        authorName = work.author
        authorLabel.toolTip = "View \(work.author)’s profile"
        setFollowShaded(followShaded)
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

        applyDensityMetrics()

        let dateLines = renderDates(for: work, availableTextWidth: availableTextWidth)

        spine.layer?.backgroundColor = NSColor(work.spineColor).cgColor
        // One fandom per line, matching the work-details header.
        fandomLabel.preferredMaxLayoutWidth = max(60, availableTextWidth)
        fandomLabel.stringValue = work.fandomList.joined(separator: "\n")

        renderTitle(for: work, dateLines: dateLines, isNew: isNew, isRemoved: isRemoved,
                    availableTextWidth: availableTextWidth)

        let author = NSMutableAttributedString(
            string: "by ", attributes: [.font: MacFont.ui(12), .foregroundColor: theme.nsInk3])
        author.append(NSAttributedString(
            string: work.author, attributes: [.font: MacFont.ui(12, weight: .semibold), .foregroundColor: theme.nsInk2]))
        authorLabel.attributedStringValue = author

        summaryLabel.stringValue = work.summary
        summaryClip.isHidden = work.summary.isEmpty

        renderTags(for: work, tagsExpanded: tagsExpanded, availableTextWidth: availableTextWidth)
        let heights = Self.summaryHeights(text: work.summary, width: availableTextWidth)
        collapsedSummaryHeight = heights.collapsed
        fullSummaryHeight = heights.full
        summaryHeight.constant = summaryExpanded ? fullSummaryHeight : collapsedSummaryHeight

        var meta = " \(Fmt.k(work.kudos))   \(Fmt.k(work.words)) words   \(work.chapterCount)/\(work.complete ? String(work.totalChapters) : "?")"
        if downloaded {
            meta += "   ⤓ Offline"
        }
        metaText = meta
        renderMeta()

        progressTrack.isHidden = progress <= 0

        // One VoiceOver element per row — reads the work as a sentence
        // instead of a soup of unlabeled text fragments.
        setAccessibilityElement(true)
        setAccessibilityRole(.staticText)
        setAccessibilityLabel(Self.axDescription(for: work, progress: progress,
                                                 downloaded: downloaded, bookmarked: bookmarked,
                                                 finished: finished))

        applyTheme()
        if progress > 0 {
            layoutSubtreeIfNeeded()
            progressWidth.constant = progressTrack.bounds.width * progress
        }
    }

    private func applyDensityMetrics() {
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
    }

    private func renderDates(for work: Work, availableTextWidth: CGFloat) -> [String] {
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
        titleLabel.preferredMaxLayoutWidth = availableTextWidth
        return dateLines
    }

    private func renderTitle(for work: Work, dateLines: [String], isNew: Bool, isRemoved: Bool,
                             availableTextWidth: CGFloat) {
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
        // The dates block occupies the row's top-right corner. The opening
        // title line(s) wrap short of it; every line below runs full width.
        var datesSize = NSSize.zero
        if !dateLines.isEmpty {
            let size = datesLabel.intrinsicContentSize
            datesSize = NSSize(width: size.width + 10, height: size.height)
        }
        // The pills share the corner — keep the title clear of them too.
        if isNew { datesSize.width += 44 }
        if isRemoved { datesSize.width += 66 }
        if isNew || isRemoved { datesSize.height = max(datesSize.height, 16) }
        titleLabel.attributedStringValue = Self.wrappedAroundDates(
            title, width: availableTextWidth, datesSize: datesSize)
    }

    private func renderTags(for work: Work, tagsExpanded: Bool, availableTextWidth: CGFloat) {
        tagsClip.isHidden = work.tags.isEmpty
        if !work.tags.isEmpty {
            let sortedTags = work.tags.sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
            let tags = NSMutableAttributedString()
            for (index, tag) in sortedTags.enumerated() {
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
    }

    /// Whether the signed-in user has left kudos on this work — the heart
    /// in the meta line turns red, matching the reader's kudos button.
    var kudosGiven = false
    /// Meta text after the heart glyph; kept so the heart can be recolored
    /// without recomputing the line.
    var metaText = ""
    /// The user's manual finished-reading flag — "✓ Finished" in the meta
    /// line.
    var finished = false

}
