import AppKit

final class SubscriptionRowCellView: NSTableCellView {
    static let reuseID = NSUserInterfaceItemIdentifier("SubscriptionRowCell")

    private let theme: AppTheme
    private let iconView = NSImageView()
    private let nameLabel = NSTextField(labelWithString: "")
    private let typeLabel = NSTextField(labelWithString: "")
    private let chevron = NSImageView()
    private let separator = NSView()

    init(theme: AppTheme) {
        self.theme = theme
        super.init(frame: .zero)
        wantsLayer = true

        iconView.imageScaling = .scaleProportionallyDown
        iconView.contentTintColor = theme.nsAccent

        nameLabel.lineBreakMode = .byTruncatingTail
        nameLabel.maximumNumberOfLines = 1

        typeLabel.lineBreakMode = .byTruncatingTail

        chevron.image = NSImage(systemSymbolName: "chevron.right",
                                accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 10, weight: .semibold))
        chevron.contentTintColor = theme.nsInk3

        separator.wantsLayer = true

        for v in [iconView, nameLabel, typeLabel, chevron, separator] {
            v.translatesAutoresizingMaskIntoConstraints = false
            addSubview(v)
        }

        NSLayoutConstraint.activate([
            iconView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
            iconView.centerYAnchor.constraint(equalTo: centerYAnchor),
            iconView.widthAnchor.constraint(equalToConstant: 16),
            iconView.heightAnchor.constraint(equalToConstant: 16),

            nameLabel.leadingAnchor.constraint(equalTo: iconView.trailingAnchor, constant: 10),
            nameLabel.topAnchor.constraint(equalTo: topAnchor, constant: 10),
            nameLabel.trailingAnchor.constraint(lessThanOrEqualTo: chevron.leadingAnchor, constant: -8),

            typeLabel.leadingAnchor.constraint(equalTo: nameLabel.leadingAnchor),
            typeLabel.topAnchor.constraint(equalTo: nameLabel.bottomAnchor, constant: 2),
            typeLabel.trailingAnchor.constraint(lessThanOrEqualTo: chevron.leadingAnchor, constant: -8),

            chevron.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -14),
            chevron.centerYAnchor.constraint(equalTo: centerYAnchor),
            chevron.widthAnchor.constraint(equalToConstant: 10),

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

    func configure(with sub: USubscription, isLoading: Bool, isActive: Bool) {
        let typeName: String
        let iconName: String
        switch sub.subType.lowercased() {
        case let t where t.contains("author"):
            typeName = "Author"
            iconName = "person"
        case let t where t.contains("series"):
            typeName = "Series"
            iconName = "square.stack"
        default:
            typeName = "Work"
            iconName = "book.closed"
        }

        nameLabel.font = MacFont.ui(14, weight: .semibold)
        typeLabel.font = MacFont.ui(12)
        nameLabel.stringValue = sub.name
        typeLabel.stringValue = isLoading ? "Fetching works…" : typeName
        iconView.image = NSImage(systemSymbolName: iconName,
                                 accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 12, weight: .semibold))
        nameLabel.textColor = isActive ? theme.nsAccent : theme.nsInk
        chevron.isHidden = sub.subType.lowercased().contains("series")
    }

    func applyTheme() {
        typeLabel.textColor = theme.nsInk3
        iconView.contentTintColor = theme.nsAccent
        chevron.contentTintColor = theme.nsInk3
        separator.layer?.backgroundColor = theme.nsLine.cgColor
    }
}
