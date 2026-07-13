import AppKit
import SwiftUI

/// Middle pane: contextual list driven by the selected sidebar section.
/// Work lists render in an NSTableView; the managed-list variants
/// (subscriptions, fandoms, authors, stats) are hosted SwiftUI.
final class ListPaneViewController: NSViewController, NSTableViewDataSource, NSTableViewDelegate {
    private let theme: AppTheme
    private let model: MacAppModel

    private let toolbar: PaneToolbarView
    private let contentStack = NSStackView()
    private let scrollView = NSScrollView()
    private let tableView = NSTableView()

    private var chipsHost: NSHostingView<ChipsBar>?
    private var variantHost: NSView?
    private var emptyHost: NSView?
    private var eyeButton: ToolButton?

    private var works: [Work] = []
    private var renderedSection: MacAppModel.Section?
    private var expandedSummaries: Set<String> = []

    init(theme: AppTheme, model: MacAppModel) {
        self.theme = theme
        self.model = model
        self.toolbar = PaneToolbarView(theme: theme)
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override func loadView() {
        let root = NSView()
        root.wantsLayer = true

        let column = NSTableColumn(identifier: .init("work"))
        column.resizingMask = .autoresizingMask
        tableView.addTableColumn(column)
        tableView.headerView = nil
        tableView.style = .plain
        tableView.usesAutomaticRowHeights = true
        tableView.selectionHighlightStyle = .none
        tableView.intercellSpacing = .zero
        tableView.gridStyleMask = .solidHorizontalGridLineMask
        tableView.dataSource = self
        tableView.delegate = self
        tableView.backgroundColor = .clear

        scrollView.documentView = tableView
        scrollView.hasVerticalScroller = true
        scrollView.drawsBackground = false

        contentStack.orientation = .vertical
        contentStack.spacing = 0
        contentStack.distribution = .fill

        toolbar.translatesAutoresizingMaskIntoConstraints = false
        contentStack.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(toolbar)
        root.addSubview(contentStack)
        NSLayoutConstraint.activate([
            toolbar.topAnchor.constraint(equalTo: root.topAnchor),
            toolbar.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            toolbar.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            contentStack.topAnchor.constraint(equalTo: toolbar.bottomAnchor),
            contentStack.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            contentStack.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            contentStack.bottomAnchor.constraint(equalTo: root.bottomAnchor),
        ])
        view = root

        ObservationRelay.track { [weak self] in
            self?.render()
        }
    }

    // MARK: - Render

    private func render() {
        view.layer?.backgroundColor = theme.nsBg.cgColor
        tableView.gridColor = theme.nsLine
        toolbar.applyTheme()

        let section = model.section
        switch section {
        case .browse, .search:
            let query = model.query.trimmingCharacters(in: .whitespaces)
            works = model.searchResults
            toolbar.configure(title: query.isEmpty ? "Browse" : "“\(query)”", sub: "\(works.count) works")
            configureEyeButton()
            showWorksContent(section: section, chips: true,
                             empty: works.isEmpty ? ("magnifyingglass", "No works found", "Try a different tag or search term.") : nil)

        case .reading, .later, .history, .bookmarks, .downloads:
            works = model.works(for: section)
            let meta = Self.sectionMeta[section]!
            toolbar.configure(title: meta.title, sub: "\(works.count) · \(meta.sub)")
            toolbar.setTrailing([])
            showWorksContent(section: section, chips: false,
                             empty: works.isEmpty ? meta.empty : nil)

        case .subscriptions:
            toolbar.configure(title: "Subscriptions", sub: "Followed updates")
            let markRead = ToolButton(theme: theme, symbol: "checkmark", tooltip: "Mark all read") { [weak self] in
                self?.model.notifsRead = true
            }
            toolbar.setTrailing(model.notifsRead ? [] : [markRead])
            showVariant(SubscriptionsList(theme: theme, model: model), section: section)

        case .fandoms:
            toolbar.configure(title: "Fandoms", sub: "\(MacMockData.fandoms.count) followed")
            toolbar.setTrailing([])
            showVariant(FandomsGrid(theme: theme, model: model), section: section)

        case .authors:
            toolbar.configure(title: "Authors", sub: "\(MacMockData.authors.count) followed")
            toolbar.setTrailing([])
            showVariant(AuthorsList(theme: theme, model: model), section: section)

        case .stats:
            toolbar.configure(title: "Reading Stats", sub: "Counted on device")
            toolbar.setTrailing([])
            showVariant(StatsView(theme: theme), section: section)
        }
        renderedSection = section
    }

    private static let sectionMeta: [MacAppModel.Section: (title: String, sub: String, empty: (String, String, String))] = [
        .reading: ("Currently Reading", "In progress", ("book", "Nothing in progress", "Open a work to begin reading.")),
        .later: ("Want to Read", "Saved for later", ("pin", "Nothing saved", "Add works to read later.")),
        .history: ("History", "Recently read", ("clock", "No history yet", "Works you read appear here.")),
        .bookmarks: ("Bookmarks", "Saved works", ("bookmark", "No bookmarks", "Bookmark works to keep them.")),
        .downloads: ("Downloaded", "Available offline", ("arrow.down.circle", "No downloads", "Download works to read offline.")),
    ]

    private func configureEyeButton() {
        let eye = eyeButton ?? ToolButton(theme: theme, symbol: "eye", tooltip: "Hide explicit") { [weak self] in
            guard let self else { return }
            model.hideExplicit.toggle()
        }
        eyeButton = eye
        eye.isOn = model.hideExplicit
        eye.setSymbol(model.hideExplicit ? "eye.slash" : "eye")
        toolbar.setTrailing([eye])
    }

    // MARK: - Content swapping

    private func showWorksContent(section: MacAppModel.Section, chips: Bool, empty: (String, String, String)?) {
        variantHost?.removeFromSuperview()
        variantHost = nil

        if chips {
            if chipsHost == nil {
                let host = NSHostingView(rootView: ChipsBar(theme: theme, model: model))
                chipsHost = host
            }
            if chipsHost!.superview == nil {
                contentStack.insertArrangedSubview(chipsHost!, at: 0)
                chipsHost!.widthAnchor.constraint(equalTo: contentStack.widthAnchor).isActive = true
            }
        } else {
            chipsHost?.removeFromSuperview()
        }

        if scrollView.superview == nil {
            contentStack.addArrangedSubview(scrollView)
            scrollView.widthAnchor.constraint(equalTo: contentStack.widthAnchor).isActive = true
        }

        emptyHost?.removeFromSuperview()
        emptyHost = nil
        if let empty {
            let host = NSHostingView(rootView: EmptyStateMac(theme: theme, icon: empty.0, title: empty.1, message: empty.2))
            host.translatesAutoresizingMaskIntoConstraints = false
            scrollView.addSubview(host)
            NSLayoutConstraint.activate([
                host.centerXAnchor.constraint(equalTo: scrollView.centerXAnchor),
                host.centerYAnchor.constraint(equalTo: scrollView.centerYAnchor),
                host.widthAnchor.constraint(equalTo: scrollView.widthAnchor),
            ])
            emptyHost = host
        }

        let sectionChanged = renderedSection != section
        tableView.reloadData()
        if sectionChanged {
            tableView.scroll(.zero)
        }
        // Keep the table's native selection in sync with the model (reading
        // model.selectedWorkID here also makes the relay re-render on selection
        // change, which repaints the previously selected row).
        if let selectedRow = works.firstIndex(where: { $0.id == model.selectedWorkID }) {
            if tableView.selectedRow != selectedRow {
                tableView.selectRowIndexes(IndexSet(integer: selectedRow), byExtendingSelection: false)
            }
        } else {
            tableView.deselectAll(nil)
        }
    }

    private func showVariant(_ content: some View, section: MacAppModel.Section) {
        chipsHost?.removeFromSuperview()
        scrollView.removeFromSuperview()
        emptyHost?.removeFromSuperview()
        emptyHost = nil
        // Rebuild the host when the section changes; re-render otherwise.
        if renderedSection != section || variantHost == nil {
            variantHost?.removeFromSuperview()
            let host = NSHostingView(rootView: AnyView(content))
            contentStack.addArrangedSubview(host)
            host.widthAnchor.constraint(equalTo: contentStack.widthAnchor).isActive = true
            variantHost = host
        } else if let host = variantHost as? NSHostingView<AnyView> {
            host.rootView = AnyView(content)
        }
    }

    // MARK: - Table

    func numberOfRows(in tableView: NSTableView) -> Int {
        works.count
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let cell: WorkRowCellView
        if let reused = tableView.makeView(withIdentifier: WorkRowCellView.reuseID, owner: self) as? WorkRowCellView {
            cell = reused
        } else {
            cell = WorkRowCellView(theme: theme)
            cell.identifier = WorkRowCellView.reuseID
        }
        let work = works[row]
        // Row chrome: 16 leading + 3 spine + 12 gap + 40 trailing.
        let textWidth = max(100, tableView.bounds.width - 71)
        cell.configure(with: work, model: model, selected: model.selectedWorkID == work.id,
                       summaryExpanded: expandedSummaries.contains(work.id),
                       availableTextWidth: textWidth)
        cell.onToggleSummary = { [weak self] in
            self?.toggleSummary(workID: work.id)
        }
        return cell
    }

    private func toggleSummary(workID: String) {
        if expandedSummaries.contains(workID) {
            expandedSummaries.remove(workID)
        } else {
            expandedSummaries.insert(workID)
        }
        guard let row = works.firstIndex(where: { $0.id == workID }) else { return }
        // Expanding a summary is also an act of focusing that work — select it
        // (fires tableViewSelectionDidChange → model.selectWork).
        tableView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        let indexes = IndexSet(integer: row)
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.2
            tableView.reloadData(forRowIndexes: indexes, columnIndexes: [0])
            tableView.noteHeightOfRows(withIndexesChanged: indexes)
        }
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        guard tableView.selectedRow >= 0, tableView.selectedRow < works.count else { return }
        let id = works[tableView.selectedRow].id
        // Ignore no-op changes from programmatic selection sync — selectWork
        // closes an open reader, which must only happen on a real user click.
        if model.selectedWorkID != id {
            model.selectWork(id)
        }
    }

    // The full text belongs in the expanded row, not in the hover overlay.
    func tableView(_ tableView: NSTableView, shouldShowCellExpansionFor tableColumn: NSTableColumn?, row: Int) -> Bool {
        false
    }
}
