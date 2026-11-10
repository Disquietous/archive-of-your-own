import AppKit

/// Header control for a source whose reaction shape is a star rating
/// (design/source-controls-plan.md): one star per step up to `max`. A
/// click sets that value; clicking the current value clears it. Faded
/// while a request is in flight. Hidden entirely for other shapes — the
/// header asks the row's controls which to show.
final class StarRatingToolControl: NSView {
    var onSelect: ((UInt8?) -> Void)?

    private let theme: AppTheme
    private let stack = NSStackView()
    private var stars: [NSButton] = []
    private(set) var max: UInt8 = 5
    private(set) var value: UInt8?
    private var pending = false
    private var enabled = true

    init(theme: AppTheme) {
        self.theme = theme
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        stack.orientation = .horizontal
        stack.spacing = 0
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
            heightAnchor.constraint(equalToConstant: 30),
        ])
        rebuild()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    /// `reason` is shown as the tooltip when disabled ("Sign in to rate").
    func configure(max: UInt8, value: UInt8?, pending: Bool, enabled: Bool, verb: String, reason: String?) {
        if max != self.max { self.max = max; rebuild() }
        self.value = value
        self.pending = pending
        self.enabled = enabled && !pending
        toolTip = enabled ? (value.map { "\(verb) — yours: \($0) of \(max). Click your star again to clear." } ?? verb)
                          : (reason ?? verb)
        refresh()
    }

    private func rebuild() {
        stars.forEach { $0.removeFromSuperview() }
        stars = (1...Swift.max(1, Int(max))).map { step in
            let b = NSButton(frame: .zero)
            b.isBordered = false
            b.bezelStyle = .regularSquare
            b.tag = step
            b.target = self
            b.action = #selector(starClicked(_:))
            b.translatesAutoresizingMaskIntoConstraints = false
            (b.cell as? NSButtonCell)?.imageDimsWhenDisabled = false
            NSLayoutConstraint.activate([
                b.widthAnchor.constraint(equalToConstant: 20),
                b.heightAnchor.constraint(equalToConstant: 30),
            ])
            return b
        }
        stars.forEach { stack.addArrangedSubview($0) }
        refresh()
    }

    private func refresh() {
        let filled = Int(value ?? 0)
        for b in stars {
            let on = b.tag <= filled
            b.image = NSImage(systemSymbolName: on ? "star.fill" : "star", accessibilityDescription: "\(b.tag) stars")?
                .withSymbolConfiguration(.init(pointSize: 13, weight: .medium))
            let tint = on ? theme.nsAccent : theme.nsInk3
            b.contentTintColor = pending ? tint.withAlphaComponent(0.45) : tint
            b.isEnabled = enabled
        }
    }

    @objc private func starClicked(_ sender: NSButton) {
        guard enabled else { return }
        let step = UInt8(sender.tag)
        onSelect?(step == value ? nil : step)
    }
}
