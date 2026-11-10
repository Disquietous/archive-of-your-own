import AppKit

/// The Search section's top-level tabs: one per source that searches, in
/// the registry's order (AO3 first), each its badge and name in the same
/// segmented track as `ScopeTabsView`. Clicking reports the source id to
/// `onSelect`; the owning render calls `configure(selected:)` back with
/// the model's tab so the highlight always reflects model state.
final class SourceTabsView: NSView {
    private let theme: AppTheme
    private var segments: [(id: String, button: NSButton)] = []
    var onSelect: ((String) -> Void)?

    var segmentCount: Int { segments.count }

    init(theme: AppTheme, sources: [SourceCapabilities]) {
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

        for (index, source) in sources.enumerated() {
            if index > 0 {
                let divider = NSView()
                divider.wantsLayer = true
                divider.layer?.backgroundColor = theme.nsLine.cgColor
                stack.addArrangedSubview(divider)
                divider.widthAnchor.constraint(equalToConstant: 1).isActive = true
                divider.heightAnchor.constraint(equalToConstant: 12).isActive = true
            }
            let button = NSButton(title: source.name, target: self, action: #selector(segmentClicked(_:)))
            button.isBordered = false
            button.setButtonType(.momentaryChange)
            button.wantsLayer = true
            button.layer?.cornerRadius = 6
            button.font = MacFont.ui(12, weight: .semibold)
            button.imagePosition = .imageLeading
            button.imageHugsTitle = true
            button.tag = segments.count
            segments.append((source.id, button))
            stack.addArrangedSubview(button)
            button.heightAnchor.constraint(equalToConstant: 24).isActive = true
        }
        applyTheme(selected: sources.first?.id ?? "")
        for (_, button) in segments {
            button.widthAnchor.constraint(
                equalToConstant: ceil(button.intrinsicContentSize.width) + 24).isActive = true
        }
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    @objc private func segmentClicked(_ sender: NSButton) {
        guard sender.tag < segments.count else { return }
        onSelect?(segments[sender.tag].id)
    }

    func configure(selected: String) {
        applyTheme(selected: selected)
    }

    private func applyTheme(selected: String) {
        layer?.backgroundColor = theme.nsSurface2.cgColor
        for (id, button) in segments {
            let active = id == selected
            let ink = active ? theme.nsInk : theme.nsInk3
            button.layer?.backgroundColor = active ? theme.nsSurface.cgColor : NSColor.clear.cgColor
            button.attributedTitle = NSAttributedString(
                string: button.title,
                attributes: [.font: MacFont.ui(12, weight: .semibold), .foregroundColor: ink])
            button.image = SourceBadge.tinted(for: id, color: ink, height: 12)
        }
    }
}
