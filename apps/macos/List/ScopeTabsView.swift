import AppKit

/// The search title bar's scope tabs: one text button per SearchScope in a
/// segmented-control track (surface2 behind, surface fill on the active
/// segment, hairline dividers between segments) — the same visual grammar
/// as the settings segment controls. Each tab is its title plus the same
/// padding, so the gaps between tabs are equal.
/// Exactly one tab is active; clicking reports the scope to `onSelect`,
/// and the owning render calls `configure(selected:)` back with model
/// state, so the highlight always reflects the model (never local state).
final class ScopeTabsView: NSView {
    private let theme: AppTheme
    private var segments: [(scope: MacSearchModel.SearchScope, button: NSButton)] = []
    var onSelect: ((MacSearchModel.SearchScope) -> Void)?

    init(theme: AppTheme) {
        self.theme = theme
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 8

        let stack = NSStackView()
        stack.orientation = .horizontal
        stack.spacing = 2
        stack.edgeInsets = NSEdgeInsets(top: 2, left: 2, bottom: 2, right: 2)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])

        for (index, scope) in MacSearchModel.SearchScope.allCases.enumerated() {
            if index > 0 {
                let divider = NSView()
                divider.wantsLayer = true
                divider.layer?.backgroundColor = theme.nsLine.cgColor
                stack.addArrangedSubview(divider)
                divider.widthAnchor.constraint(equalToConstant: 1).isActive = true
                divider.heightAnchor.constraint(equalToConstant: 12).isActive = true
            }
            let button = NSButton(title: scope.rawValue, target: self, action: #selector(segmentClicked(_:)))
            button.isBordered = false
            button.setButtonType(.momentaryChange)
            button.wantsLayer = true
            button.layer?.cornerRadius = 6
            button.font = MacFont.ui(12, weight: .semibold)
            button.tag = segments.count
            segments.append((scope, button))
            stack.addArrangedSubview(button)
            // Identical padding around every title, whatever its length, so
            // the empty space between neighboring tabs stays uniform.
            button.widthAnchor.constraint(
                equalToConstant: ceil(button.intrinsicContentSize.width) + 24).isActive = true
            button.heightAnchor.constraint(equalToConstant: 24).isActive = true
        }
        applyTheme(selected: .works)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    @objc private func segmentClicked(_ sender: NSButton) {
        guard sender.tag < segments.count else { return }
        onSelect?(segments[sender.tag].scope)
    }

    /// Reflect the model's scope: the selected segment gets the raised
    /// surface and full-ink title, the rest sit muted on the track.
    func configure(selected: MacSearchModel.SearchScope) {
        applyTheme(selected: selected)
    }

    private func applyTheme(selected: MacSearchModel.SearchScope) {
        layer?.backgroundColor = theme.nsSurface2.cgColor
        for (scope, button) in segments {
            let active = scope == selected
            button.layer?.backgroundColor = active ? theme.nsSurface.cgColor : NSColor.clear.cgColor
            button.attributedTitle = NSAttributedString(
                string: scope.rawValue,
                attributes: [
                    .font: MacFont.ui(12, weight: .semibold),
                    .foregroundColor: active ? theme.nsInk : theme.nsInk3,
                ])
        }
    }
}
