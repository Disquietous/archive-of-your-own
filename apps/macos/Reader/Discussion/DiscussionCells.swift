import AppKit

/// Base for every thread-table cell: flipped, layer-backed, and draws the
/// thread lines of the ancestors this row sits under. Clicking a line
/// collapses that ancestor's thread.
class DiscussionGuideCell: NSView {
    weak var controller: DiscussionThreadController?
    var style: DiscussionStyle?
    var guides: [UInt64] = []
    var indent = 0

    override var isFlipped: Bool { true }

    required override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        // Lines and boxes are drawn relative to the width, so a resize must
        // redraw — otherwise they stay where the old width put them.
        layerContentsRedrawPolicy = .duringViewResize
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    var column: (x: CGFloat, width: CGFloat) { DiscussionStyle.column(in: bounds.width) }
    /// Left edge of this row's content at its indent.
    var contentX: CGFloat { column.x + CGFloat(indent) * DiscussionStyle.indentStep }

    func drawGuides() {
        guard let style, !guides.isEmpty else { return }
        style.line2.setFill()
        for level in guides.indices {
            let x = DiscussionStyle.guideX(level: level, columnX: column.x)
            NSBezierPath(rect: NSRect(x: x - 1, y: 0, width: 2, height: bounds.height)).fill()
        }
    }

    override func draw(_ dirtyRect: NSRect) { drawGuides() }

    /// The ancestor whose line is under `point`, if any.
    func guideHit(_ point: NSPoint) -> UInt64? {
        for level in guides.indices where abs(point.x - DiscussionStyle.guideX(level: level, columnX: column.x)) <= 8 {
            return guides[level]
        }
        return nil
    }

    override func mouseDown(with event: NSEvent) {
        if let id = guideHit(convert(event.locationInWindow, from: nil)) {
            controller?.collapse(id)
        } else {
            super.mouseDown(with: event)
        }
    }

    override func resetCursorRects() {
        for level in guides.indices {
            let x = DiscussionStyle.guideX(level: level, columnX: column.x)
            addCursorRect(NSRect(x: x - 8, y: 0, width: 16, height: bounds.height), cursor: .pointingHand)
        }
    }
}

/// Selectable, non-editable comment text (TextKit 1 so it lays out exactly
/// like `DiscussionMeasure`). A click also selects the row; right-click
/// shows the comment's menu with Copy for any selected text.
final class DiscussionBodyTextView: NSTextView {
    var onMouseDown: (() -> Void)?
    var commentMenu: (() -> NSMenu?)?

    init() {
        let storage = NSTextStorage()
        let layout = NSLayoutManager()
        storage.addLayoutManager(layout)
        let container = NSTextContainer(size: NSSize(width: 100, height: CGFloat.greatestFiniteMagnitude))
        container.lineFragmentPadding = 0
        container.widthTracksTextView = true
        layout.addTextContainer(container)
        super.init(frame: .zero, textContainer: container)
        isEditable = false
        isSelectable = true
        drawsBackground = false
        textContainerInset = .zero
        isVerticallyResizable = false
        isHorizontallyResizable = false
        isRichText = true
    }

    override init(frame frameRect: NSRect, textContainer container: NSTextContainer?) {
        super.init(frame: frameRect, textContainer: container)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func mouseDown(with event: NSEvent) {
        onMouseDown?()
        super.mouseDown(with: event)
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        guard let menu = commentMenu?() else { return super.menu(for: event) }
        if selectedRange().length > 0 {
            menu.insertItem(.separator(), at: 0)
            menu.insertItem(NSMenuItem(title: "Copy", action: #selector(copy(_:)), keyEquivalent: ""), at: 0)
            menu.item(at: 0)?.target = self
        }
        return menu
    }
}

/// A label that can act like a link (author names).
final class DiscussionLabel: NSTextField {
    var onClick: (() -> Void)?

    static func make() -> DiscussionLabel {
        let l = DiscussionLabel(labelWithString: "")
        l.lineBreakMode = .byTruncatingTail
        l.maximumNumberOfLines = 1
        l.cell?.truncatesLastVisibleLine = true
        return l
    }

    override func mouseDown(with event: NSEvent) {
        if let onClick { onClick() } else { super.mouseDown(with: event) }
    }

    override func resetCursorRects() {
        if onClick != nil { addCursorRect(bounds, cursor: .pointingHand) }
    }
}

// MARK: - Small rows

/// "N more replies" (collapsed thread) or "Load N more replies" (AO3 cut
/// the thread short) — one link, or a spinner while loading.
final class DiscussionLinkCell: DiscussionGuideCell {
    private let button = NSButton(title: "", target: nil, action: nil)
    private let spinner = NSProgressIndicator()
    private let label = DiscussionLabel.make()
    private var onPress: (() -> Void)?
    private var xOffset: CGFloat = 0

    required init(frame: NSRect) {
        super.init(frame: frame)
        button.isBordered = false
        button.target = self
        button.action = #selector(press)
        spinner.style = .spinning
        spinner.controlSize = .mini
        for v in [button, spinner, label] as [NSView] { addSubview(v) }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func configure(title: String, chevron: Bool, loading: Bool, xOffset: CGFloat, onPress: @escaping () -> Void) {
        guard let style else { return }
        self.onPress = onPress
        self.xOffset = xOffset
        let text = NSMutableAttributedString()
        if chevron {
            let symbol = NSImage(systemSymbolName: "chevron.right", accessibilityDescription: nil)
            let attachment = NSTextAttachment()
            attachment.image = symbol?.withSymbolConfiguration(.init(pointSize: 9, weight: .bold))
            text.append(NSAttributedString(attachment: attachment))
            text.append(NSAttributedString(string: " "))
        }
        text.append(NSAttributedString(string: title))
        text.addAttributes([.font: style.linkFont, .foregroundColor: style.accent],
                           range: NSRange(location: 0, length: text.length))
        button.attributedTitle = text
        button.contentTintColor = style.accent
        button.isHidden = loading
        spinner.isHidden = !loading
        label.isHidden = !loading
        label.stringValue = "Loading replies…"
        label.font = style.smallFont
        label.textColor = style.ink3
        if loading { spinner.startAnimation(nil) } else { spinner.stopAnimation(nil) }
        needsLayout = true
        needsDisplay = true
        window?.invalidateCursorRects(for: self)
    }

    override func layout() {
        super.layout()
        let x = contentX + xOffset
        let size = button.attributedTitle.size()
        button.frame = NSRect(x: x, y: (bounds.height - size.height - 4) / 2, width: size.width + 4, height: size.height + 4)
        spinner.frame = NSRect(x: x, y: (bounds.height - 12) / 2, width: 12, height: 12)
        label.sizeToFit()
        label.frame.origin = NSPoint(x: x + 18, y: (bounds.height - label.frame.height) / 2)
    }

    @objc private func press() { onPress?() }
}

/// The 1pt rule between top-level threads.
final class DiscussionSeparatorCell: DiscussionGuideCell {
    override func draw(_ dirtyRect: NSRect) {
        guard let style else { return }
        style.line.setFill()
        let c = column
        NSBezierPath(rect: NSRect(x: c.x + 8, y: floor(bounds.midY), width: max(0, c.width - 16), height: 1)).fill()
    }
}

/// A post AO3 hasn't confirmed — or rejected, with Retry / Edit / Discard.
final class DiscussionPendingCell: DiscussionGuideCell {
    static let xOffset: CGFloat = 38
    private let body = DiscussionBodyTextView()
    private let spinner = NSProgressIndicator()
    private let status = DiscussionLabel.make()
    private var buttons: [NSButton] = []
    private var item: DiscussionModel.Pending?

    required init(frame: NSRect) {
        super.init(frame: frame)
        spinner.style = .spinning
        spinner.controlSize = .mini
        buttons = ["Retry", "Edit", "Discard"].enumerated().map { i, title in
            let b = NSButton(title: title, target: self, action: #selector(press(_:)))
            b.isBordered = false
            b.tag = i
            return b
        }
        for v in [body, spinner, status] + buttons as [NSView] { addSubview(v) }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    static func bodyText(_ item: DiscussionModel.Pending, style: DiscussionStyle) -> NSAttributedString {
        NSAttributedString(string: item.body, attributes: [
            .font: style.bodyFont,
            .foregroundColor: style.ink2.withAlphaComponent(item.state == .posting ? 0.6 : 1),
        ])
    }

    /// Box width inside a row of `width` at `indent`.
    static func textWidth(rowWidth: CGFloat, indent: Int) -> CGFloat {
        DiscussionStyle.column(in: rowWidth).width - CGFloat(indent) * DiscussionStyle.indentStep - xOffset - 20
    }

    static func height(_ item: DiscussionModel.Pending, style: DiscussionStyle, rowWidth: CGFloat, indent: Int) -> CGFloat {
        4 + 10 + DiscussionMeasure.height(bodyText(item, style: style),
                                          width: textWidth(rowWidth: rowWidth, indent: indent)) + 6 + 18 + 10 + 4
    }

    func configure(_ item: DiscussionModel.Pending) {
        guard let style else { return }
        self.item = item
        body.textStorage?.setAttributedString(Self.bodyText(item, style: style))
        status.font = style.smallFont
        switch item.state {
        case .posting:
            spinner.isHidden = false
            spinner.startAnimation(nil)
            status.stringValue = "Posting…"
            status.textColor = style.ink3
            buttons.forEach { $0.isHidden = true }
        case .failed(let message):
            spinner.isHidden = true
            spinner.stopAnimation(nil)
            status.stringValue = message
            status.textColor = style.danger
            for b in buttons {
                b.isHidden = false
                b.attributedTitle = NSAttributedString(string: b.title, attributes: [
                    .font: style.linkFont, .foregroundColor: style.accent,
                ])
            }
        }
        needsLayout = true
        needsDisplay = true
    }

    override func layout() {
        super.layout()
        let box = boxRect
        let textWidth = box.width - 20
        let bodyHeight = max(0, box.height - 20 - 6 - 18)
        body.frame = NSRect(x: box.minX + 10, y: box.minY + 10, width: textWidth, height: bodyHeight)
        var x = box.minX + 10
        let y = body.frame.maxY + 6
        if !spinner.isHidden {
            spinner.frame = NSRect(x: x, y: y + 3, width: 12, height: 12)
            x += 18
        }
        let buttonWidths = buttons.filter { !$0.isHidden }.map { $0.attributedTitle.size().width + 6 }
        let reserved = buttonWidths.reduce(0) { $0 + $1 + 8 }
        status.frame = NSRect(x: x, y: y, width: max(0, box.maxX - 10 - x - reserved), height: 18)
        x = status.frame.maxX + 8
        for b in buttons where !b.isHidden {
            let w = b.attributedTitle.size().width + 6
            b.frame = NSRect(x: x, y: y, width: w, height: 18)
            x += w + 8
        }
    }

    private var boxRect: NSRect {
        let x = contentX + Self.xOffset
        return NSRect(x: x, y: 4, width: max(0, column.x + column.width - x), height: bounds.height - 8)
    }

    override func draw(_ dirtyRect: NSRect) {
        drawGuides()
        guard let style else { return }
        let path = NSBezierPath(roundedRect: boxRect.insetBy(dx: 0.5, dy: 0.5), xRadius: 8, yRadius: 8)
        path.lineWidth = 1
        path.setLineDash([4, 3], count: 2, phase: 0)
        style.line.setStroke()
        path.stroke()
    }

    @objc private func press(_ sender: NSButton) {
        guard let item, let model = controller?.model else { return }
        switch sender.tag {
        case 0: model.retry(item.id)
        case 1: model.edit(item.id)
        default: model.discard(item.id)
        }
    }
}
