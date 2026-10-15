import AppKit

/// One comment row: avatar, byline (name, badges, time), optional
/// "replying to", selectable body with live links. Reply / copy / more sit
/// inline just before the date; right-click shows the same actions.
/// Frame-based layout — rows are measured off-screen, never by Auto Layout.
final class DiscussionCommentCell: DiscussionGuideCell, NSTextViewDelegate {
    private let avatarView = NSImageView()
    private let nameLabel = DiscussionLabel.make()
    private let badges = (0..<3).map { _ in DiscussionLabel.make() }
    private let timeLabel = DiscussionLabel.make()
    private let replyingLabel = DiscussionLabel.make()
    private let body = DiscussionBodyTextView()
    private let actions = NSView()
    private let replyButton = DiscussionCommentCell.iconButton("arrowshape.turn.up.left", "Reply (R)")
    private let copyButton = DiscussionCommentCell.iconButton("doc.on.doc", "Copy text")
    private let moreButton = DiscussionCommentCell.iconButton("ellipsis", "More")

    private(set) var item: DiscussionCommentItem?
    private var canReply = false
    private var badgeCount = 0
    var isSelected = false { didSet { if isSelected != oldValue { needsDisplay = true } } }
    var isHighlighted = false { didSet { if isHighlighted != oldValue { needsDisplay = true } } }
    private var hovering = false {
        didSet { if hovering != oldValue { applyHover() } }
    }

    required init(frame: NSRect) {
        super.init(frame: frame)
        avatarView.wantsLayer = true
        avatarView.layer?.cornerRadius = DiscussionStyle.avatar / 2
        avatarView.layer?.masksToBounds = true
        avatarView.imageScaling = .scaleProportionallyUpOrDown
        for b in badges {
            b.wantsLayer = true
            b.alignment = .center
            b.layer?.cornerRadius = 7
            b.layer?.borderWidth = 0
        }
        body.delegate = self
        body.onMouseDown = { [weak self] in self?.selectSelf() }
        body.commentMenu = { [weak self] in self?.commentMenu() }
        replyButton.target = self
        replyButton.action = #selector(reply)
        copyButton.target = self
        copyButton.action = #selector(copyText)
        moreButton.target = self
        moreButton.action = #selector(showMore(_:))
        for b in [replyButton, copyButton, moreButton] { actions.addSubview(b) }
        for v in [avatarView, nameLabel, timeLabel, replyingLabel, body, actions] + badges as [NSView] {
            addSubview(v)
        }
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    private static func iconButton(_ symbol: String, _ help: String) -> NSButton {
        let b = NSButton(image: NSImage(systemSymbolName: symbol, accessibilityDescription: help)?
            .withSymbolConfiguration(.init(pointSize: 11, weight: .semibold)) ?? NSImage(),
                         target: nil, action: nil)
        b.isBordered = false
        b.toolTip = help
        return b
    }

    // MARK: - Measuring

    static func textWidth(rowWidth: CGFloat, indent: Int) -> CGFloat {
        DiscussionStyle.column(in: rowWidth).width - CGFloat(indent) * DiscussionStyle.indentStep
            - DiscussionStyle.textX - DiscussionStyle.pad
    }

    static func height(_ item: DiscussionCommentItem, body: NSAttributedString, rowWidth: CGFloat) -> CGFloat {
        let bodyHeight = DiscussionMeasure.height(body, width: textWidth(rowWidth: rowWidth, indent: item.indent))
        let content = DiscussionStyle.bylineHeight
            + (item.replyingTo == nil ? 0 : DiscussionStyle.replyingHeight)
            + (bodyHeight > 0 ? 4 + bodyHeight : 0)
        return max(content, DiscussionStyle.avatar) + DiscussionStyle.pad * 2 + 2
    }

    // MARK: - Configure

    func configure(_ item: DiscussionCommentItem, body text: NSAttributedString, avatar: NSImage,
                   canReply: Bool, selected: Bool, highlighted: Bool) {
        guard let style else { return }
        self.item = item
        self.canReply = canReply && item.comment.notice.isEmpty
        guides = item.guides
        indent = item.indent
        isSelected = selected
        isHighlighted = highlighted
        let c = item.comment
        let hasNotice = !c.notice.isEmpty

        avatarView.image = avatar
        avatarView.alphaValue = hasNotice ? 0.4 : 1
        nameLabel.isHidden = hasNotice
        nameLabel.stringValue = c.displayName
        nameLabel.font = style.nameFont
        nameLabel.textColor = style.ink
        let profile = !c.isGuest && !c.authorProfileUrl.isEmpty
        nameLabel.onClick = profile ? { [weak self] in self?.controller?.openAuthor(c.authorName) } : nil
        nameLabel.toolTip = profile ? "View \(c.displayName)’s profile" : nil

        var badgeSpecs: [(String, NSColor, Bool)] = []
        if !hasNotice {
            if item.isCreator { badgeSpecs.append(("Author", style.accent, true)) }
            if c.isGuest { badgeSpecs.append(("Guest", style.ink3, true)) }
            if !item.chapterChip.isEmpty { badgeSpecs.append((item.chapterChip, style.ink3, false)) }
        }
        badgeCount = badgeSpecs.count
        for (i, label) in badges.enumerated() {
            guard i < badgeSpecs.count else { label.isHidden = true; continue }
            let (text, tint, filled) = badgeSpecs[i]
            label.isHidden = false
            label.stringValue = text
            label.font = style.badgeFont
            label.textColor = tint
            label.layer?.backgroundColor = filled ? tint.withAlphaComponent(0.14).cgColor : NSColor.clear.cgColor
            label.layer?.borderWidth = filled ? 0 : 1
            label.layer?.borderColor = style.line.cgColor
        }

        timeLabel.stringValue = DiscussionText.relative(c.postedAt)
        timeLabel.font = style.timeFont
        timeLabel.textColor = style.ink3
        timeLabel.toolTip = c.postedAt
        timeLabel.alignment = .right

        replyingLabel.isHidden = item.replyingTo == nil
        replyingLabel.stringValue = item.replyingTo.map { "↳ replying to \($0)" } ?? ""
        replyingLabel.font = style.smallFont
        replyingLabel.textColor = style.ink3

        body.textStorage?.setAttributedString(text)
        body.linkTextAttributes = [.foregroundColor: style.accent, .cursor: NSCursor.pointingHand]
        body.selectedTextAttributes = [.backgroundColor: style.accentSoft]

        for b in [replyButton, copyButton, moreButton] { b.contentTintColor = style.ink3 }
        replyButton.isHidden = !self.canReply
        actions.isHidden = hasNotice

        let replies = c.replies.count
        var ax = [c.displayName, timeLabel.stringValue]
        if item.isCreator { ax.append("work author") }
        if replies > 0 { ax.append("\(replies) repl\(replies == 1 ? "y" : "ies")") }
        setAccessibilityLabel(ax.joined(separator: ", "))

        hovering = isMouseInside
        applyHover()
        needsLayout = true
        needsDisplay = true
        window?.invalidateCursorRects(for: self)
    }

    func setAvatar(_ image: NSImage) { avatarView.image = image }

    // MARK: - Layout & drawing

    private var boxRect: NSRect {
        NSRect(x: contentX, y: 1, width: max(0, column.x + column.width - contentX), height: bounds.height - 2)
    }

    override func layout() {
        super.layout()
        let box = boxRect
        let pad = DiscussionStyle.pad
        avatarView.frame = NSRect(x: box.minX + pad, y: box.minY + pad,
                                  width: DiscussionStyle.avatar, height: DiscussionStyle.avatar)
        let textX = box.minX + DiscussionStyle.textX
        let textRight = box.maxX - pad
        let lineY = box.minY + pad

        timeLabel.sizeToFit()
        let timeWidth = timeLabel.frame.width
        timeLabel.frame = NSRect(x: textRight - timeWidth, y: lineY, width: timeWidth, height: DiscussionStyle.bylineHeight)

        // Actions sit just before the date, on the byline.
        let size: CGFloat = 22
        let shown = actions.isHidden ? [] : [replyButton, copyButton, moreButton].filter { !$0.isHidden }
        for (i, b) in shown.enumerated() {
            b.frame = NSRect(x: CGFloat(i) * size, y: 0, width: size, height: DiscussionStyle.bylineHeight)
        }
        let actionsWidth = CGFloat(shown.count) * size
        actions.frame = NSRect(x: timeLabel.frame.minX - 4 - actionsWidth, y: lineY,
                               width: actionsWidth, height: DiscussionStyle.bylineHeight)

        var x = textX
        let limit = (shown.isEmpty ? timeLabel.frame.minX : actions.frame.minX) - 6
        nameLabel.sizeToFit()
        nameLabel.frame = NSRect(x: x, y: lineY, width: min(nameLabel.frame.width, max(0, limit - x)),
                                 height: DiscussionStyle.bylineHeight)
        x = nameLabel.frame.maxX + 6
        for b in badges.prefix(badgeCount) {
            b.sizeToFit()
            let w = b.frame.width + 12
            b.frame = NSRect(x: x, y: lineY + 2, width: w, height: 14)
            b.isHidden = x + w > limit
            x += w + 4
        }

        var y = lineY + DiscussionStyle.bylineHeight
        if !replyingLabel.isHidden {
            replyingLabel.frame = NSRect(x: textX, y: y, width: max(0, textRight - textX), height: 15)
            y += DiscussionStyle.replyingHeight
        }
        // The row was measured off-screen; the body takes what's left.
        body.frame = NSRect(x: textX, y: y + 4, width: max(0, textRight - textX),
                            height: max(0, box.maxY - pad - y - 4))
    }

    override func draw(_ dirtyRect: NSRect) {
        drawGuides()
        guard let style, let item else { return }
        let fill: NSColor? = isHighlighted ? style.accentSoft
            : isSelected ? style.surface2
            : hovering ? style.surface.withAlphaComponent(0.7) : nil
        if let fill {
            fill.setFill()
            NSBezierPath(roundedRect: boxRect, xRadius: 8, yRadius: 8).fill()
        }
        if item.ownsLine {
            style.line2.setFill()
            let x = DiscussionStyle.guideX(level: indent, columnX: column.x)
            let top = boxRect.minY + DiscussionStyle.pad + DiscussionStyle.avatar + 4
            NSBezierPath(roundedRect: NSRect(x: x - 1, y: top, width: 2, height: max(0, bounds.height - top)),
                         xRadius: 1, yRadius: 1).fill()
        }
    }

    // MARK: - Mouse

    private var ownLineRect: NSRect? {
        guard item?.ownsLine == true else { return nil }
        let x = DiscussionStyle.guideX(level: indent, columnX: column.x)
        let top = boxRect.minY + DiscussionStyle.pad + DiscussionStyle.avatar + 4
        return NSRect(x: x - 8, y: top, width: 16, height: max(0, bounds.height - top))
    }

    override func mouseDown(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        if let id = guideHit(p) {
            controller?.collapse(id)
        } else if let r = ownLineRect, r.contains(p), let id = item?.comment.id {
            controller?.collapse(id)
        } else {
            selectSelf()
        }
    }

    override func resetCursorRects() {
        super.resetCursorRects()
        if let r = ownLineRect { addCursorRect(r, cursor: .pointingHand) }
    }

    private func selectSelf() {
        if let id = item?.comment.id { controller?.select(id) }
    }

    override func menu(for event: NSEvent) -> NSMenu? { commentMenu() }

    private func commentMenu() -> NSMenu? {
        guard let item else { return nil }
        return controller?.menu(for: item.comment)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
                                       owner: self, userInfo: nil))
        hovering = isMouseInside
    }

    private var isMouseInside: Bool {
        guard let window else { return false }
        return bounds.contains(convert(window.mouseLocationOutsideOfEventStream, from: nil))
    }

    override func mouseEntered(with event: NSEvent) { hovering = true }
    override func mouseExited(with event: NSEvent) { hovering = false }

    private func applyHover() { needsDisplay = true }

    // MARK: - Actions

    @objc private func reply() {
        if let c = item?.comment { controller?.model.reply(to: c) }
    }

    @objc private func copyText() {
        if let c = item?.comment { controller?.copy(c) }
    }

    @objc private func showMore(_ sender: NSButton) {
        guard let menu = commentMenu() else { return }
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: sender.bounds.height + 2), in: sender)
    }

    func textView(_ textView: NSTextView, clickedOnLink link: Any, at charIndex: Int) -> Bool {
        let url = (link as? URL) ?? (link as? String).flatMap(URL.init(string:))
        if let url { controller?.openURL(url) }
        return true
    }
}
