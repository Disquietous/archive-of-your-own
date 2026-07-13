import AppKit

/// Middle pane: list of works. Mock data for now; swaps to AppState-backed data
/// the same way the iOS screens did.
final class WorkListViewController: NSViewController, NSTableViewDataSource, NSTableViewDelegate {
    var onSelect: ((Work) -> Void)?

    private let works = MockData.works
    private let tableView = NSTableView()

    override func loadView() {
        let column = NSTableColumn(identifier: .init("work"))
        column.resizingMask = .autoresizingMask
        tableView.addTableColumn(column)
        tableView.headerView = nil
        tableView.style = .inset
        tableView.rowHeight = 52
        tableView.dataSource = self
        tableView.delegate = self
        tableView.allowsEmptySelection = true

        let scrollView = NSScrollView()
        scrollView.documentView = tableView
        scrollView.hasVerticalScroller = true
        scrollView.drawsBackground = false
        view = scrollView
    }

    // MARK: - NSTableViewDataSource

    func numberOfRows(in tableView: NSTableView) -> Int {
        works.count
    }

    // MARK: - NSTableViewDelegate

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let identifier = NSUserInterfaceItemIdentifier("WorkCell")
        let cell: WorkCellView
        if let reused = tableView.makeView(withIdentifier: identifier, owner: self) as? WorkCellView {
            cell = reused
        } else {
            cell = WorkCellView()
            cell.identifier = identifier
        }
        cell.configure(with: works[row])
        return cell
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        guard tableView.selectedRow >= 0 else { return }
        onSelect?(works[tableView.selectedRow])
    }
}

private final class WorkCellView: NSTableCellView {
    private let titleLabel = NSTextField(labelWithString: "")
    private let subtitleLabel = NSTextField(labelWithString: "")

    init() {
        super.init(frame: .zero)

        titleLabel.font = .systemFont(ofSize: 13, weight: .semibold)
        titleLabel.lineBreakMode = .byTruncatingTail
        subtitleLabel.font = .systemFont(ofSize: 11)
        subtitleLabel.textColor = .secondaryLabelColor
        subtitleLabel.lineBreakMode = .byTruncatingTail

        let stack = NSStackView(views: [titleLabel, subtitleLabel])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 2
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    func configure(with work: Work) {
        titleLabel.stringValue = work.title
        let words = NumberFormatter.localizedString(from: NSNumber(value: work.words), number: .decimal)
        subtitleLabel.stringValue = "\(work.author) · \(work.fandom) · \(words) words"
    }
}
