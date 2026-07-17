import AppKit

/// The 52px toolbar that sits above the list pane and reading pane content.
final class PaneToolbarView: NSView {
    private let theme: AppTheme
    private let titleLabel = NSTextField(labelWithString: "")
    private let subLabel = NSTextField(labelWithString: "")
    private let leadingStack = NSStackView()
    private let trailingStack = NSStackView()
    private let separator = NSView()

    init(theme: AppTheme) {
        self.theme = theme
        super.init(frame: .zero)

        titleLabel.lineBreakMode = .byTruncatingTail
        subLabel.lineBreakMode = .byTruncatingTail

        let titleStack = NSStackView(views: [titleLabel, subLabel])
        titleStack.orientation = .vertical
        titleStack.alignment = .leading
        titleStack.spacing = 0

        leadingStack.orientation = .horizontal
        leadingStack.spacing = 8
        // Center views on the midline explicitly: hosted SwiftUI views have no
        // meaningful baseline, and baseline-derived alignment pins their top
        // edge to the midline instead.
        leadingStack.alignment = .centerY
        trailingStack.orientation = .horizontal
        trailingStack.spacing = 4
        trailingStack.alignment = .centerY

        let bar = NSStackView(views: [leadingStack, titleStack, NSView(), trailingStack])
        bar.orientation = .horizontal
        bar.spacing = 10
        bar.alignment = .centerY
        bar.translatesAutoresizingMaskIntoConstraints = false
        addSubview(bar)

        separator.wantsLayer = true
        separator.translatesAutoresizingMaskIntoConstraints = false
        addSubview(separator)

        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: 52),
            bar.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
            bar.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            bar.centerYAnchor.constraint(equalTo: centerYAnchor),
            separator.leadingAnchor.constraint(equalTo: leadingAnchor),
            separator.trailingAnchor.constraint(equalTo: trailingAnchor),
            separator.bottomAnchor.constraint(equalTo: bottomAnchor),
            separator.heightAnchor.constraint(equalToConstant: 1),
        ])
        applyTheme()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    func configure(title: String, sub: String?) {
        titleLabel.stringValue = title
        subLabel.stringValue = sub ?? ""
        subLabel.isHidden = sub == nil
    }

    func setLeading(_ views: [NSView]) {
        leadingStack.setViews(views, in: .leading)
        leadingStack.isHidden = views.isEmpty
    }

    func setTrailing(_ views: [NSView]) {
        trailingStack.setViews(views, in: .trailing)
    }

    func applyTheme() {
        // Fonts live here (not init) so the app text-size setting applies on
        // the next render after it changes.
        titleLabel.font = MacFont.ui(15, weight: .bold)
        subLabel.font = MacFont.ui(12, weight: .medium)
        titleLabel.textColor = theme.nsInk
        subLabel.textColor = theme.nsInk3
        separator.layer?.backgroundColor = theme.nsLine.cgColor
    }
}

/// Compact labeled toolbar button ("Refresh Works" / "Cancel") — bordered
/// pill, icon + text, same hover treatment as ToolButton.
final class LabelToolButton: NSButton {
    private let theme: AppTheme
    private let callback: () -> Void
    private var hovering = false

    init(theme: AppTheme, action: @escaping () -> Void) {
        self.theme = theme
        self.callback = action
        super.init(frame: .zero)
        isBordered = false
        imagePosition = .imageLeading
        // Keep the icon next to the label and center both in the padded frame —
        // otherwise the icon pins to the button's leading edge.
        imageHugsTitle = true
        alignment = .center
        setButtonType(.momentaryPushIn)
        target = self
        self.action = #selector(fire)
        wantsLayer = true
        layer?.cornerRadius = 7
        layer?.borderWidth = 1
        translatesAutoresizingMaskIntoConstraints = false
        let tracking = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self)
        addTrackingArea(tracking)
        refresh()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    func configure(title: String, symbol: String, tooltip: String) {
        attributedTitle = NSAttributedString(string: title, attributes: [
            .font: MacFont.ui(11.5, weight: .semibold),
            .foregroundColor: theme.nsInk2,
        ])
        image = NSImage(systemSymbolName: symbol, accessibilityDescription: title)?
            .withSymbolConfiguration(.init(pointSize: 10.5, weight: .semibold))
        contentTintColor = theme.nsInk2
        toolTip = tooltip
        invalidateIntrinsicContentSize()
    }

    override var intrinsicContentSize: NSSize {
        var size = super.intrinsicContentSize
        size.width += 16
        size.height = 24
        return size
    }

    override func mouseEntered(with event: NSEvent) {
        hovering = true
        refresh()
    }

    override func mouseExited(with event: NSEvent) {
        hovering = false
        refresh()
    }

    private func refresh() {
        layer?.borderColor = theme.nsLine.cgColor
        layer?.backgroundColor = hovering
            ? theme.nsInk.withAlphaComponent(0.08).cgColor
            : theme.nsSurface.cgColor
    }

    @objc private func fire() {
        callback()
    }
}

/// 30×30 icon button used across pane toolbars — hover tint, optional "on" accent state.
final class ToolButton: NSButton {
    private let theme: AppTheme
    private var hovering = false
    var isOn = false {
        didSet { refresh() }
    }
    /// Icon tint when set (e.g. accent for an active bookmark) without the "on" fill.
    var tintOverride: NSColor? {
        didSet { refresh() }
    }

    init(theme: AppTheme, symbol: String, tooltip: String, action: @escaping () -> Void) {
        self.theme = theme
        self.callback = action
        super.init(frame: .zero)
        isBordered = false
        bezelStyle = .regularSquare
        image = NSImage(systemSymbolName: symbol, accessibilityDescription: tooltip)?
            .withSymbolConfiguration(.init(pointSize: 14, weight: .medium))
        toolTip = tooltip
        target = self
        self.action = #selector(fire)
        wantsLayer = true
        layer?.cornerRadius = 7
        translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: 30),
            heightAnchor.constraint(equalToConstant: 30),
        ])
        let tracking = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self)
        addTrackingArea(tracking)
        refresh()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    private let callback: () -> Void

    @objc private func fire() {
        callback()
    }

    func setSymbol(_ symbol: String) {
        image = NSImage(systemSymbolName: symbol, accessibilityDescription: toolTip)?
            .withSymbolConfiguration(.init(pointSize: 14, weight: .medium))
        refresh()
    }

    override func mouseEntered(with event: NSEvent) {
        hovering = true
        refresh()
    }

    override func mouseExited(with event: NSEvent) {
        hovering = false
        refresh()
    }

    func refresh() {
        if isOn {
            layer?.backgroundColor = theme.nsAccent.cgColor
            contentTintColor = theme.nsOnAccent
        } else {
            layer?.backgroundColor = hovering ? theme.nsInk.withAlphaComponent(0.08).cgColor : NSColor.clear.cgColor
            contentTintColor = tintOverride ?? theme.nsInk2
        }
    }
}
