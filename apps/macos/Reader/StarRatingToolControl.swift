import AppKit

/// Header control for a source whose reaction shape is a star rating
/// (design/source-controls-plan.md): the site's average to one decimal
/// beside a single star ("4.1 ★"). A click drops a menu of 1…`max` stars
/// with the reader's own rating checked; picking a different value sends
/// it. The star is filled once the reader has rated. Faded while a request
/// is in flight. When the gate is closed the menu still opens and leads
/// with the reason ("Sign in to rate"). Hidden entirely for other shapes —
/// the header asks the row's controls which to show.
final class StarRatingToolControl: NSButton {
    var onSelect: ((UInt8?) -> Void)?

    private let theme: AppTheme
    private(set) var max: UInt8 = 5
    private(set) var value: UInt8?
    private var average: String?
    private var pending = false
    private var canRate = true
    private var verb = ""
    private var reason: String?

    init(theme: AppTheme) {
        self.theme = theme
        super.init(frame: .zero)
        isBordered = false
        bezelStyle = .regularSquare
        imagePosition = .imageTrailing
        imageHugsTitle = true
        target = self
        action = #selector(showMenu)
        translatesAutoresizingMaskIntoConstraints = false
        heightAnchor.constraint(equalToConstant: 30).isActive = true
        setContentHuggingPriority(.required, for: .horizontal)
        refresh()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    /// `average` is the site's average as shown ("4.1"), nil when the work
    /// is unrated. `reason` explains a closed gate ("Sign in to rate").
    func configure(max: UInt8, value: UInt8?, average: String?, pending: Bool, enabled: Bool, verb: String, reason: String?) {
        self.max = max
        self.value = value
        self.average = average
        self.pending = pending
        self.canRate = enabled
        self.verb = verb
        self.reason = reason
        toolTip = enabled ? (value.map { "\(verb) — yours: \($0) of \(max)" } ?? verb) : (reason ?? verb)
        refresh()
    }

    private func refresh() {
        let fade: CGFloat = pending ? 0.45 : 1
        attributedTitle = NSAttributedString(string: average ?? "", attributes: [
            .font: MacFont.ui(13, weight: .medium),
            .foregroundColor: theme.nsInk2.withAlphaComponent(fade),
        ])
        let rated = value != nil
        image = NSImage(systemSymbolName: rated ? "star.fill" : "star",
                        accessibilityDescription: average.map { "Rated \($0) of \(max)" } ?? "Not yet rated")?
            .withSymbolConfiguration(.init(pointSize: 13, weight: .medium))
        contentTintColor = (rated ? theme.nsAccent : theme.nsInk3).withAlphaComponent(fade)
        invalidateIntrinsicContentSize()
    }

    override var intrinsicContentSize: NSSize {
        var size = super.intrinsicContentSize
        size.width += 8
        return size
    }

    @objc private func showMenu() {
        let menu = NSMenu()
        menu.autoenablesItems = false
        let open = canRate && !pending
        if !canRate, let reason, !reason.isEmpty {
            let note = NSMenuItem(title: reason, action: nil, keyEquivalent: "")
            note.isEnabled = false
            menu.addItem(note)
            menu.addItem(.separator())
        }
        for step in 1...Swift.max(1, Int(max)) {
            let item = NSMenuItem(title: step == 1 ? "1 star" : "\(step) stars",
                                  action: #selector(pick(_:)), keyEquivalent: "")
            item.target = self
            item.tag = step
            item.state = Int(value ?? 0) == step ? .on : .off
            item.isEnabled = open
            menu.addItem(item)
        }
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: bounds.height + 4), in: self)
    }

    @objc private func pick(_ sender: NSMenuItem) {
        let step = UInt8(sender.tag)
        guard canRate, !pending, step != value else { return }
        onSelect?(step)
    }
}
