import AppKit

/// One bookmark hit in the bookmark results table. The work's fields are
/// drawn exactly like WorkRowCellView (fandom spine, accent fandom label,
/// serif title with inline rating badge, byline, tag pills, meta row) with
/// the bookmark's own data around them: bookmarked-by and date in the
/// top-right corner (with a REC pill), the bookmarker's accented tag pills
/// under the work's tags, and the bookmark note above the meta row.
final class BookmarkRowCellView: NSTableCellView {
    static let reuseID = NSUserInterfaceItemIdentifier("BookmarkRowCell")

    private let theme: AppTheme
    private let spine = NSView()
    private let fandomLabel = NSTextField(wrappingLabelWithString: "")
    private let titleLabel = NSTextField(wrappingLabelWithString: "")
    private let authorLabel = NSTextField(labelWithString: "")
    private let noteLabel = NSTextField(wrappingLabelWithString: "")
    private let metaLabel = NSTextField(labelWithString: "")
    /// Top-right corner block: REC pill + bookmarked-by on the first line,
    /// the bookmark date on the second (the work row's dates slot).
    private let cornerLabel = NSTextField(labelWithString: "")
    private let workTagsLabel = NSTextField(wrappingLabelWithString: "")
    private let workTagsClip = NSView()
    private var workTagsHeight: NSLayoutConstraint!
    private var collapsedWorkTagsHeight: CGFloat = 0
    private var fullWorkTagsHeight: CGFloat = 0
    private let bookmarkerTagsLabel = NSTextField(wrappingLabelWithString: "")
    private let bookmarkerTagsClip = NSView()
    private var bookmarkerTagsHeight: NSLayoutConstraint!
    private var collapsedBookmarkerTagsHeight: CGFloat = 0
    private var fullBookmarkerTagsHeight: CGFloat = 0
    /// Per-row bottom hairline, as in WorkRowCellView.
    private let separator = NSView()

    private var bodyStack: NSStackView!
    private var bodyTop: NSLayoutConstraint!
    private var bodyBottom: NSLayoutConstraint!
    private var spineTop: NSLayoutConstraint!
    private var spineBottom: NSLayoutConstraint!
    private var cornerTop: NSLayoutConstraint!

    /// Called when the user clicks a tag block to expand/collapse it.
    var onToggleWorkTags: (() -> Void)?
    var onToggleBookmarkerTags: (() -> Void)?

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

    /// Shared measuring labels — one for attributed tag pills, one for the
    /// plain note text, so attributed content never bleeds between them.
    private static let tagsMeasureLabel = NSTextField(wrappingLabelWithString: "")

    init(theme: AppTheme) {
        self.theme = theme
        super.init(frame: .zero)
        wantsLayer = true

        spine.wantsLayer = true
        spine.layer?.cornerRadius = 1.5

        fandomLabel.font = MacFont.ui(11, weight: .bold)
        fandomLabel.maximumNumberOfLines = 0
        fandomLabel.isSelectable = false
        titleLabel.font = MacFont.serif(16, weight: .semibold)
        titleLabel.maximumNumberOfLines = 0
        // Selectable wrapping labels consume row clicks and drop the inline
        // rating-badge attachment — same reasoning as WorkRowCellView.
        titleLabel.isSelectable = false
        authorLabel.font = MacFont.ui(12)
        authorLabel.lineBreakMode = .byTruncatingTail
        noteLabel.font = MacFont.ui(12.5)
        noteLabel.maximumNumberOfLines = 3
        noteLabel.isSelectable = false
        metaLabel.font = MacFont.ui(11, weight: .medium)
        metaLabel.lineBreakMode = .byTruncatingTail

        cornerLabel.font = MacFont.ui(10, weight: .medium)
        cornerLabel.alignment = .right
        cornerLabel.maximumNumberOfLines = 2

        func setUpTagClip(_ clip: NSView, label: NSTextField, action: Selector) -> NSLayoutConstraint {
            clip.wantsLayer = true
            clip.layer?.masksToBounds = true
            clip.addGestureRecognizer(NSClickGestureRecognizer(target: self, action: action))
            label.isSelectable = false
            label.translatesAutoresizingMaskIntoConstraints = false
            clip.addSubview(label)
            let height = clip.heightAnchor.constraint(equalToConstant: 0)
            NSLayoutConstraint.activate([
                height,
                label.topAnchor.constraint(equalTo: clip.topAnchor),
                label.leadingAnchor.constraint(equalTo: clip.leadingAnchor),
                label.trailingAnchor.constraint(equalTo: clip.trailingAnchor),
            ])
            return height
        }
        workTagsHeight = setUpTagClip(workTagsClip, label: workTagsLabel,
                                      action: #selector(workTagsClicked))
        bookmarkerTagsHeight = setUpTagClip(bookmarkerTagsClip, label: bookmarkerTagsLabel,
                                            action: #selector(bookmarkerTagsClicked))

        let body = NSStackView(views: [titleLabel, authorLabel, fandomLabel,
                                       workTagsClip, bookmarkerTagsClip, noteLabel, metaLabel])
        bodyStack = body
        body.orientation = .vertical
        body.alignment = .leading
        body.spacing = 3
        body.setCustomSpacing(2, after: authorLabel)
        body.setCustomSpacing(6, after: fandomLabel)
        body.setCustomSpacing(7, after: workTagsClip)
        body.setCustomSpacing(7, after: bookmarkerTagsClip)
        body.setCustomSpacing(7, after: noteLabel)
        // Refuse vertical stretching so row-height measurement never
        // ratchets — see WorkRowCellView.
        for label in [fandomLabel, titleLabel, authorLabel, noteLabel, metaLabel] {
            label.setContentHuggingPriority(.init(751), for: .vertical)
        }

        separator.wantsLayer = true
        for view in [spine, body, cornerLabel, separator] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }

        bodyBottom = body.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -12)
        bodyBottom.priority = .defaultHigh
        bodyTop = body.topAnchor.constraint(equalTo: topAnchor, constant: 12)
        spineTop = spine.topAnchor.constraint(equalTo: topAnchor, constant: 12)
        spineBottom = spine.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -12)
        cornerTop = cornerLabel.topAnchor.constraint(equalTo: topAnchor, constant: 12)

        NSLayoutConstraint.activate([
            bodyBottom,
            separator.leadingAnchor.constraint(equalTo: leadingAnchor),
            separator.trailingAnchor.constraint(equalTo: trailingAnchor),
            separator.bottomAnchor.constraint(equalTo: bottomAnchor),
            separator.heightAnchor.constraint(equalToConstant: 1),

            spine.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
            spineTop,
            spineBottom,
            spine.widthAnchor.constraint(equalToConstant: 3),

            body.leadingAnchor.constraint(equalTo: spine.trailingAnchor, constant: 12),
            body.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -14),
            bodyTop,

            cornerTop,
            cornerLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -14),
            fandomLabel.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -14),

            workTagsClip.widthAnchor.constraint(equalTo: body.widthAnchor),
            bookmarkerTagsClip.widthAnchor.constraint(equalTo: body.widthAnchor),
        ])
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    @objc private func workTagsClicked() {
        onToggleWorkTags?()
    }

    @objc private func bookmarkerTagsClicked() {
        onToggleBookmarkerTags?()
    }

    /// Animated reveal for the tag blocks — same clip-and-constraint
    /// treatment as WorkRowCellView's tags.
    func setWorkTagsExpanded(_ expanded: Bool) {
        workTagsHeight.constant = expanded ? fullWorkTagsHeight : collapsedWorkTagsHeight
    }

    func setBookmarkerTagsExpanded(_ expanded: Bool) {
        bookmarkerTagsHeight.constant = expanded ? fullBookmarkerTagsHeight : collapsedBookmarkerTagsHeight
    }

    /// Capsule "REC" marker drawn as an image so it rides inline in the
    /// corner label. Rebuilt per configure — theme colors can change.
    private func recBadgeImage() -> NSImage {
        let text = NSAttributedString(string: "REC", attributes: [
            .font: MacFont.ui(8.5, weight: .heavy),
            .foregroundColor: theme.nsOnAccent,
        ])
        let textSize = text.size()
        let size = NSSize(width: textSize.width + 10, height: 13)
        let accent = theme.nsAccent
        return NSImage(size: size, flipped: false) { rect in
            accent.setFill()
            NSBezierPath(roundedRect: rect, xRadius: rect.height / 2, yRadius: rect.height / 2).fill()
            text.draw(at: NSPoint(x: (rect.width - textSize.width) / 2,
                                  y: (rect.height - textSize.height) / 2))
            return true
        }
    }

    /// The work row's tag pill run: sorted tags as background-colored runs.
    /// Accented pills mark the bookmarker's own tags apart from work tags.
    private func pillString(_ tags: [String], accented: Bool) -> NSAttributedString {
        let sorted = tags.sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
        let pills = NSMutableAttributedString()
        for (index, tag) in sorted.enumerated() {
            if index > 0 {
                pills.append(NSAttributedString(string: "  ", attributes: [.font: MacFont.ui(10.5)]))
            }
            pills.append(NSAttributedString(string: " \(tag) ", attributes: [
                .font: MacFont.ui(10.5, weight: .semibold),
                .foregroundColor: accented ? theme.nsAccent : theme.nsInk2,
                .backgroundColor: accented ? theme.nsAccentSoft : theme.nsSurface2,
            ]))
        }
        return pills
    }

    /// Measure a tag pill run's collapsed (2-line) and full heights.
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

    private func configureTagClip(_ tags: [String], accented: Bool, expanded: Bool,
                                  clip: NSView, label: NSTextField,
                                  heightConstraint: NSLayoutConstraint,
                                  width: CGFloat) -> (collapsed: CGFloat, full: CGFloat) {
        clip.isHidden = tags.isEmpty
        guard !tags.isEmpty else { return (0, 0) }
        let pills = pillString(tags, accented: accented)
        label.attributedStringValue = pills
        let heights = Self.tagsHeights(text: pills, width: width)
        heightConstraint.constant = expanded ? heights.full : heights.collapsed
        return heights
    }

    func configure(with hit: UBookmarkHit,
                   workTagsExpanded: Bool, bookmarkerTagsExpanded: Bool,
                   availableTextWidth: CGFloat) {
        let work = hit.work

        // Chrome fonts are assigned here, not in init, so the app text-size
        // setting (MacFont.scale) applies on every (re)configure.
        fandomLabel.font = MacFont.ui(11, weight: .bold)
        noteLabel.font = MacFont.ui(12.5)
        metaLabel.font = MacFont.ui(11, weight: .medium)
        cornerLabel.font = MacFont.ui(10, weight: .medium)

        // Density (Settings → Spacing) sets the row's breathing room.
        let vPad = Self.verticalPad(for: theme.density)
        let gap = Self.sectionGap(for: theme.density)
        bodyTop.constant = vPad
        bodyBottom.constant = -vPad
        spineTop.constant = vPad
        spineBottom.constant = -vPad
        cornerTop.constant = vPad
        bodyStack.setCustomSpacing(gap, after: workTagsClip)
        bodyStack.setCustomSpacing(gap, after: bookmarkerTagsClip)
        bodyStack.setCustomSpacing(gap, after: noteLabel)

        workTagsLabel.preferredMaxLayoutWidth = availableTextWidth
        bookmarkerTagsLabel.preferredMaxLayoutWidth = availableTextWidth
        noteLabel.preferredMaxLayoutWidth = availableTextWidth
        titleLabel.preferredMaxLayoutWidth = availableTextWidth

        // Corner block: REC pill + bookmarked-by, date beneath — the
        // bookmark's data in the work row's dates slot.
        let right = NSMutableParagraphStyle()
        right.alignment = .right
        let cornerFont = MacFont.ui(10, weight: .medium)
        let corner = NSMutableAttributedString()
        if hit.rec {
            let badge = NSTextAttachment()
            let image = recBadgeImage()
            badge.image = image
            badge.bounds = CGRect(x: 0, y: cornerFont.capHeight - image.size.height + 2,
                                  width: image.size.width, height: image.size.height)
            corner.append(NSAttributedString(attachment: badge))
            corner.append(NSAttributedString(string: " "))
        }
        corner.append(NSAttributedString(
            string: hit.bookmarker.isEmpty ? "Bookmarked" : "Bookmarked by \(hit.bookmarker)"))
        if !hit.dateBookmarked.isEmpty {
            corner.append(NSAttributedString(string: "\n\(hit.dateBookmarked)"))
        }
        corner.addAttributes([
            .font: cornerFont,
            .foregroundColor: theme.nsInk3,
            .paragraphStyle: right,
        ], range: NSRange(location: 0, length: corner.length))
        cornerLabel.attributedStringValue = corner

        spine.layer?.backgroundColor = NSColor(Fandom.spineColor(for: work.fandoms.first ?? "Unknown Fandom")).cgColor
        // One fandom per line, matching the work list item. A mystery hit
        // (unrevealed challenge work) has no fandoms — its "Part of
        // <collection>" line rides the fandom slot, as on AO3.
        fandomLabel.preferredMaxLayoutWidth = max(60, availableTextWidth)
        if hit.mystery && work.fandoms.isEmpty && !hit.mysteryCollectionTitle.isEmpty {
            fandomLabel.stringValue = "Part of \(hit.mysteryCollectionTitle)"
        } else {
            fandomLabel.stringValue = work.fandoms.joined(separator: "\n")
        }
        fandomLabel.isHidden = fandomLabel.stringValue.isEmpty

        // Serif title with the rating badge inline after the last word,
        // wrapped short of the corner block — exactly the work row's title.
        // No badge when the rating is unknown (mystery works carry none).
        let titleFont = MacFont.serif(16, weight: .semibold)
        let title = NSMutableAttributedString(
            string: work.title + "\u{00A0}",
            attributes: [.font: titleFont, .foregroundColor: theme.nsInk])
        if let rating = Rating(rawValue: work.rating) {
            let badge = NSTextAttachment()
            badge.image = WorkRowCellView.ratingBadgeImage(for: rating)
            badge.bounds = CGRect(x: 0, y: (titleFont.capHeight - WorkRowCellView.badgeSize) / 2,
                                  width: WorkRowCellView.badgeSize, height: WorkRowCellView.badgeSize)
            title.append(NSAttributedString(attachment: badge))
        }
        let cornerSize = cornerLabel.intrinsicContentSize
        titleLabel.attributedStringValue = WorkRowCellView.wrappedAroundDates(
            title, width: availableTextWidth,
            datesSize: NSSize(width: cornerSize.width + 10, height: cornerSize.height))

        // Mystery works have no byline at all; other blurbs without an
        // author link (anonymous works) keep the "Unknown" fallback.
        authorLabel.isHidden = hit.mystery
        let authors = work.authors.joined(separator: ", ")
        let author = NSMutableAttributedString(
            string: "by ", attributes: [.font: MacFont.ui(12), .foregroundColor: theme.nsInk3])
        author.append(NSAttributedString(
            string: authors.isEmpty ? "Unknown" : authors,
            attributes: [.font: MacFont.ui(12, weight: .semibold), .foregroundColor: theme.nsInk2]))
        authorLabel.attributedStringValue = author

        let workHeights = configureTagClip(
            work.relationships + work.characters + work.tags, accented: false,
            expanded: workTagsExpanded, clip: workTagsClip, label: workTagsLabel,
            heightConstraint: workTagsHeight, width: availableTextWidth)
        collapsedWorkTagsHeight = workHeights.collapsed
        fullWorkTagsHeight = workHeights.full

        let bookmarkerHeights = configureTagClip(
            hit.tags, accented: true,
            expanded: bookmarkerTagsExpanded, clip: bookmarkerTagsClip, label: bookmarkerTagsLabel,
            heightConstraint: bookmarkerTagsHeight, width: availableTextWidth)
        collapsedBookmarkerTagsHeight = bookmarkerHeights.collapsed
        fullBookmarkerTagsHeight = bookmarkerHeights.full

        noteLabel.stringValue = hit.note
        noteLabel.isHidden = hit.note.isEmpty

        // No stats exist for a mystery work — zeros would just be noise.
        metaLabel.isHidden = hit.mystery
        let total = work.complete ? String(work.totalChapters) : "?"
        metaLabel.stringValue = "♥ \(Fmt.k(Int(work.kudos)))   \(Fmt.k(Int(work.wordCount))) words   \(work.chapterCount)/\(total)"

        // One VoiceOver element per row.
        setAccessibilityElement(true)
        setAccessibilityRole(.staticText)
        setAccessibilityLabel(Self.axDescription(for: hit))

        applyTheme()
    }

    private static func axDescription(for hit: UBookmarkHit) -> String {
        let work = hit.work
        var parts: [String] = [work.title, "by \(work.authors.joined(separator: ", "))"]
        if !work.fandoms.isEmpty { parts.append(work.fandoms.joined(separator: ", ")) }
        parts.append(hit.bookmarker.isEmpty ? "bookmarked" : "bookmarked by \(hit.bookmarker)")
        if hit.rec { parts.append("recommended") }
        if !hit.dateBookmarked.isEmpty { parts.append("on \(hit.dateBookmarked)") }
        parts.append("\(Fmt.k(Int(work.wordCount))) words")
        if !hit.note.isEmpty { parts.append("note: \(hit.note)") }
        return parts.joined(separator: ", ")
    }

    func applyTheme() {
        layer?.backgroundColor = NSColor.clear.cgColor
        separator.layer?.backgroundColor = theme.nsLine.cgColor
        fandomLabel.textColor = theme.nsAccent
        titleLabel.textColor = theme.nsInk
        noteLabel.textColor = theme.nsInk2
        metaLabel.textColor = theme.nsInk3
    }
}
