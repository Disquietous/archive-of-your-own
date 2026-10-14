import AppKit
import SwiftUI

/// The scrolling thread list as a view-based NSTableView over the model's
/// flattened rows. Rows are measured off-screen once per comment and width.
/// The list reloads only when its rows actually change. Selection, hover,
/// highlight and avatar arrivals update visible cells in place.
/// Keyboard: ↑/↓ select, ←/→ collapse/expand, R reply, ⌘C copy.
@MainActor
final class DiscussionThreadController: NSObject, NSTableViewDataSource, NSTableViewDelegate {
    let model: DiscussionModel
    private let theme: AppTheme
    private let appState: AppState
    var actions: () -> DiscussionActions = { DiscussionActions(openAuthor: { _ in }, openURL: { _ in }) }

    let view = NSView()
    private let scrollView = NSScrollView()
    private let table = DiscussionTableView()
    private var statesHost: NSHostingView<DiscussionStatesView>!
    private var footerHost: NSHostingView<DiscussionFooterView>!
    private let avatars: DiscussionAvatarLoader

    private var rows: [DiscussionRow] = []
    private var style: DiscussionStyle
    private var canReply = false
    private var selectedID: UInt64?
    private var highlightID: UInt64?
    /// Rendered bodies and measured heights, per comment id.
    private var bodies: [UInt64: NSAttributedString] = [:]
    private var bodyQuery: String?
    private var heights: [UInt64: CGFloat] = [:]
    private var measuredWidth: CGFloat = 0
    private var retileTask: Task<Void, Never>?
    private var syncingSelection = false
    /// Last scroll (or panel open); avatar fetches wait for this to go quiet.
    private var lastScroll = Date()
    private var idleTask: Task<Void, Never>?
    /// Seconds the list must be still before avatars are fetched.
    static let avatarIdleSeconds: TimeInterval = 2

    init(model: DiscussionModel, theme: AppTheme, appState: AppState) {
        self.model = model
        self.theme = theme
        self.appState = appState
        self.style = DiscussionStyle(theme: theme)
        self.avatars = DiscussionAvatarLoader(appState: appState)
        super.init()
        build()
        observe()
    }

    // MARK: - Build

    private func build() {
        let column = NSTableColumn(identifier: .init("thread"))
        column.resizingMask = .autoresizingMask
        table.addTableColumn(column)
        table.headerView = nil
        table.style = .plain
        table.intercellSpacing = .zero
        table.selectionHighlightStyle = .none
        table.usesAutomaticRowHeights = false
        table.allowsTypeSelect = false
        table.focusRingType = .none
        table.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
        table.dataSource = self
        table.delegate = self
        table.controller = self

        scrollView.documentView = table
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.borderType = .noBorder
        scrollView.contentView.postsFrameChangedNotifications = true
        NotificationCenter.default.addObserver(self, selector: #selector(clipFrameChanged),
                                               name: NSView.frameDidChangeNotification, object: scrollView.contentView)
        scrollView.contentView.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(self, selector: #selector(didScroll),
                                               name: NSView.boundsDidChangeNotification, object: scrollView.contentView)

        statesHost = NSHostingView(rootView: DiscussionStatesView(theme: theme, model: model))
        statesHost.sizingOptions = []
        footerHost = NSHostingView(rootView: DiscussionFooterView(theme: theme, model: model))
        footerHost.sizingOptions = []

        for v in [scrollView, statesHost!] as [NSView] {
            v.translatesAutoresizingMaskIntoConstraints = false
            view.addSubview(v)
            NSLayoutConstraint.activate([
                v.topAnchor.constraint(equalTo: view.topAnchor),
                v.leadingAnchor.constraint(equalTo: view.leadingAnchor),
                v.trailingAnchor.constraint(equalTo: view.trailingAnchor),
                v.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            ])
        }
        applyColors()

        avatars.isEnabled = { [weak self] in self?.theme.imageAutoLoad ?? false }
        avatars.canFetch = { [weak self] in
            guard let self else { return false }
            return theme.imageAutoLoad && !model.isLoading
                && Date().timeIntervalSince(lastScroll) >= Self.avatarIdleSeconds
        }
        avatars.isWanted = { [weak self] name in self?.visibleAuthors().contains(name) ?? false }
    }

    /// Each observation applies on the next main-queue turn, so the work it
    /// does (reloads, cell updates) isn't itself tracked.
    private func observe() {
        ObservationRelay.track { [weak self] in
            guard let self else { return }
            let rows = model.buildRows()
            let query = model.isFinding ? model.findText.trimmingCharacters(in: .whitespaces) : ""
            let canReply = model.isLoggedIn
            DispatchQueue.main.async { self.apply(rows, query: query.isEmpty ? nil : query, canReply: canReply) }
        }
        ObservationRelay.track { [weak self] in
            guard let self else { return }
            let (selected, highlight) = (model.selectedID, model.highlightID)
            DispatchQueue.main.async { self.applySelection(selected, highlight: highlight) }
        }
        var first = true
        ObservationRelay.track { [weak self] in
            guard let self else { return }
            let newStyle = DiscussionStyle(theme: theme)
            _ = theme.uiFontScale
            if first { first = false; return }
            DispatchQueue.main.async { self.applyStyle(newStyle) }
        }
        ObservationRelay.track { [weak self] in
            guard let self else { return }
            _ = appState.authorAvatars
            let enabled = theme.imageAutoLoad
            DispatchQueue.main.async { self.refreshAvatars(requesting: enabled) }
        }
        ObservationRelay.track { [weak self] in
            guard let self else { return }
            if !model.isLoading && theme.imageAutoLoad { DispatchQueue.main.async { self.scheduleAvatarPump() } }
        }
    }

    // MARK: - Applying changes

    private func apply(_ new: [DiscussionRow], query: String?, canReply: Bool) {
        var changed = new != rows || canReply != self.canReply
        if query != bodyQuery {
            bodyQuery = query
            bodies = [:]
            changed = true
        }
        self.canReply = canReply
        statesHost.isHidden = new.contains { if case .comment = $0 { true } else if case .pending = $0 { true } else { false } }
        guard changed else { return }
        // Comments whose content or place changed lose their cached body/height.
        var old: [UInt64: DiscussionCommentItem] = [:]
        for case .comment(let item) in rows { old[item.comment.id] = item }
        for case .comment(let item) in new where old[item.comment.id] != item {
            bodies[item.comment.id] = nil
            heights[item.comment.id] = nil
        }
        rows = new
        table.reloadData()
        syncTableSelection()
    }

    private func applySelection(_ selected: UInt64?, highlight: UInt64?) {
        let flash = highlight != nil && highlight != highlightID
        selectedID = selected
        highlightID = highlight
        syncTableSelection()
        forEachVisibleComment { cell, item in
            cell.isSelected = item.comment.id == selected
            cell.isHighlighted = item.comment.id == highlight
        }
        if flash, let highlight, let row = rowIndex(of: highlight) { scrollToCenter(row) }
    }

    private func applyStyle(_ newStyle: DiscussionStyle) {
        style = newStyle
        bodies = [:]
        heights = [:]
        avatars.clearPlaceholders()
        applyColors()
        table.reloadData()
        syncTableSelection()
    }

    private func applyColors() {
        table.backgroundColor = style.bg
        scrollView.backgroundColor = style.bg
    }

    /// Re-show avatars (or letters) on visible rows; when images were just
    /// switched on, also ask for the ones not loaded yet.
    private func refreshAvatars(requesting: Bool) {
        forEachVisibleComment { cell, item in
            cell.setAvatar(avatarImage(for: item.comment))
            if requesting { avatars.request(item.comment) }
        }
    }

    private func syncTableSelection() {
        syncingSelection = true
        defer { syncingSelection = false }
        if let selectedID, let row = rowIndex(of: selectedID) {
            if table.selectedRow != row { table.selectRowIndexes([row], byExtendingSelection: false) }
        } else if table.selectedRow >= 0 {
            table.deselectAll(nil)
        }
    }

    /// The panel was hidden: stop asking for avatars nobody will see.
    func panelHidden() {
        idleTask?.cancel()
        avatars.cancelQueued()
    }

    /// The panel opened: give the user a quiet period before any fetch.
    func panelShown() { didScroll() }

    @objc private func didScroll() {
        lastScroll = Date()
        scheduleAvatarPump()
    }

    /// Try queued avatar fetches once the list has been still for the delay.
    private func scheduleAvatarPump() {
        idleTask?.cancel()
        let wait = max(0, Self.avatarIdleSeconds - Date().timeIntervalSince(lastScroll))
        idleTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(wait))
            guard let self, !Task.isCancelled else { return }
            avatars.pump()
        }
    }

    // MARK: - Lookup

    private func rowIndex(of id: UInt64) -> Int? {
        rows.firstIndex { $0.commentID == id }
    }

    private var visibleRange: Range<Int> {
        let r = table.rows(in: table.visibleRect)
        return max(0, r.location)..<min(rows.count, NSMaxRange(r))
    }

    private func visibleAuthors() -> Set<String> {
        var names: Set<String> = []
        for i in visibleRange { if case .comment(let item) = rows[i] { names.insert(item.comment.authorName) } }
        return names
    }

    private func forEachVisibleComment(_ body: (DiscussionCommentCell, DiscussionCommentItem) -> Void) {
        for i in visibleRange {
            guard case .comment(let item) = rows[i],
                  let cell = table.view(atColumn: 0, row: i, makeIfNecessary: false) as? DiscussionCommentCell
            else { continue }
            body(cell, item)
        }
    }

    private func body(for comment: ParsedComment) -> NSAttributedString {
        if let cached = bodies[comment.id] { return cached }
        let text = style.body(comment, highlight: bodyQuery)
        bodies[comment.id] = text
        return text
    }

    private func avatarImage(for comment: ParsedComment) -> NSImage {
        avatars.image(for: comment.authorName) ?? avatars.placeholder(for: comment.authorName, style: style)
    }

    private var rowWidth: CGFloat { scrollView.contentSize.width }

    // MARK: - Width changes

    /// Visible rows re-measure at once; the rest after the resize settles,
    /// so dragging the panel edge never measures the whole list per frame.
    @objc private func clipFrameChanged() {
        let width = rowWidth
        guard abs(width - measuredWidth) > 0.5 else { return }
        measuredWidth = width
        heights = [:]
        noteHeights(IndexSet(integersIn: visibleRange))
        retileTask?.cancel()
        retileTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(150))
            guard let self, !Task.isCancelled else { return }
            noteHeights(IndexSet(integersIn: 0..<rows.count))
        }
    }

    private func noteHeights(_ rows: IndexSet) {
        guard !rows.isEmpty else { return }
        NSAnimationContext.beginGrouping()
        NSAnimationContext.current.duration = 0
        table.noteHeightOfRows(withIndexesChanged: rows)
        NSAnimationContext.endGrouping()
    }

    private func scrollToCenter(_ row: Int) {
        let clip = scrollView.contentView
        let rect = table.rect(ofRow: row)
        let maxY = max(0, table.frame.height - clip.bounds.height)
        let y = min(max(0, rect.midY - clip.bounds.height / 2), maxY)
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.25
            ctx.allowsImplicitAnimation = true
            clip.animator().setBoundsOrigin(NSPoint(x: 0, y: y))
        }
        scrollView.reflectScrolledClipView(clip)
    }

    // MARK: - NSTableView

    func numberOfRows(in tableView: NSTableView) -> Int { rows.count }

    func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
        guard row < rows.count else { return 1 }
        switch rows[row] {
        case .comment(let item):
            if let h = heights[item.comment.id] { return h }
            let h = DiscussionCommentCell.height(item, body: body(for: item.comment), rowWidth: rowWidth)
            heights[item.comment.id] = h
            return h
        case .pending(let pending, let indent, _):
            return DiscussionPendingCell.height(pending, style: style, rowWidth: rowWidth, indent: indent)
        case .collapsed, .moreReplies:
            return DiscussionStyle.linkRowHeight
        case .separator:
            return DiscussionStyle.separatorHeight
        case .footer:
            return DiscussionFooterView.height
        }
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard row < rows.count else { return nil }
        switch rows[row] {
        case .comment(let item):
            let cell: DiscussionCommentCell = make("comment")
            cell.configure(item, body: body(for: item.comment), avatar: avatarImage(for: item.comment),
                           canReply: canReply, selected: item.comment.id == selectedID,
                           highlighted: item.comment.id == highlightID)
            avatars.request(item.comment)
            return cell
        case .pending(let pending, let indent, let guides):
            let cell: DiscussionPendingCell = make("pending")
            cell.indent = indent
            cell.guides = guides
            cell.configure(pending)
            return cell
        case .collapsed(let parent, let count, let indent, let guides):
            let cell: DiscussionLinkCell = make("link")
            cell.indent = indent
            cell.guides = guides
            cell.configure(title: "\(count) more repl\(count == 1 ? "y" : "ies")", chevron: true, loading: false,
                           xOffset: DiscussionStyle.textX) { [weak self] in self?.model.collapsed.remove(parent) }
            return cell
        case .moreReplies(let parent, let count, let loading, let indent, let guides):
            let cell: DiscussionLinkCell = make("link")
            cell.indent = indent
            cell.guides = guides
            cell.configure(title: "Load \(count) more repl\(count == 1 ? "y" : "ies")", chevron: false,
                           loading: loading, xOffset: DiscussionStyle.textX) { [weak self] in
                self?.model.loadMoreReplies(parent)
            }
            return cell
        case .separator:
            let cell: DiscussionSeparatorCell = make("separator")
            cell.needsDisplay = true
            return cell
        case .footer:
            return footerHost
        }
    }

    private func make<Cell: DiscussionGuideCell>(_ id: String) -> Cell {
        let identifier = NSUserInterfaceItemIdentifier(id)
        let cell = (table.makeView(withIdentifier: identifier, owner: nil) as? Cell) ?? {
            let c = Cell(frame: .zero)
            c.identifier = identifier
            return c
        }()
        cell.controller = self
        cell.style = style
        cell.guides = []
        cell.indent = 0
        return cell
    }

    func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool {
        row < rows.count && rows[row].commentID != nil
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        guard !syncingSelection else { return }
        let row = table.selectedRow
        model.selectedID = row >= 0 && row < rows.count ? rows[row].commentID : nil
    }
}

// MARK: - Cell & keyboard actions

extension DiscussionThreadController {
    func select(_ id: UInt64, focusList: Bool = true) {
        model.selectedID = id
        if focusList { table.window?.makeFirstResponder(table) }
    }

    func collapse(_ id: UInt64) { model.collapsed.insert(id) }

    func openAuthor(_ name: String) { actions().openAuthor(name) }
    func openURL(_ url: URL) { actions().openURL(url) }

    func copy(_ comment: ParsedComment) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(model.plainText(comment), forType: .string)
    }

    func copySelected() {
        guard let id = model.selectedID, let c = model.find(id, in: model.comments) else { return }
        copy(c)
    }

    func menu(for c: ParsedComment) -> NSMenu {
        let menu = NSMenu()
        func add(_ title: String, _ handler: @escaping () -> Void) {
            menu.addItem(DiscussionMenuItem(title: title, handler: handler))
        }
        if model.isLoggedIn && c.notice.isEmpty { add("Reply") { [weak self] in self?.model.reply(to: c) } }
        add("Copy Text") { [weak self] in self?.copy(c) }
        add("Copy Link") {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(DiscussionText.commentURL(c.id).absoluteString, forType: .string)
        }
        menu.addItem(.separator())
        add("Open on AO3") { [weak self] in self?.openURL(DiscussionText.commentURL(c.id)) }
        if !c.isGuest && !c.authorProfileUrl.isEmpty {
            add("View \(c.displayName)’s Profile") { [weak self] in self?.openAuthor(c.authorName) }
        }
        return menu
    }

    /// Handled keys return true; everything else goes to the table.
    func handleKey(_ event: NSEvent) -> Bool {
        let mods = event.modifierFlags.intersection(.deviceIndependentFlagsMask).subtracting([.function, .numericPad])
        switch event.keyCode {
        case 125, 126:  // ↓ ↑
            guard mods.isEmpty else { return false }
            moveSelection(event.keyCode == 125 ? 1 : -1)
            return true
        case 123, 124:  // ← →
            guard mods.isEmpty, let id = model.selectedID else { return false }
            if event.keyCode == 123 { model.collapsed.insert(id) } else { model.collapsed.remove(id) }
            return true
        default:
            guard mods.isEmpty, event.charactersIgnoringModifiers?.lowercased() == "r", model.isLoggedIn,
                  let id = model.selectedID, let c = model.find(id, in: model.comments) else { return false }
            model.reply(to: c)
            return true
        }
    }

    private func moveSelection(_ step: Int) {
        let commentRows = rows.indices.filter { rows[$0].commentID != nil }
        guard !commentRows.isEmpty else { return }
        let target: Int
        if let id = model.selectedID, let current = rowIndex(of: id), let i = commentRows.firstIndex(of: current) {
            target = commentRows[max(0, min(commentRows.count - 1, i + step))]
        } else {
            target = step > 0 ? commentRows[0] : commentRows[commentRows.count - 1]
        }
        model.selectedID = rows[target].commentID
        table.scrollRowToVisible(target)
    }
}

/// The thread table: routes the panel's keys and ⌘C to the controller.
final class DiscussionTableView: NSTableView {
    weak var controller: DiscussionThreadController?

    override func keyDown(with event: NSEvent) {
        if controller?.handleKey(event) == true { return }
        super.keyDown(with: event)
    }

    @objc func copy(_ sender: Any?) { controller?.copySelected() }
}

/// A menu item that runs a closure.
final class DiscussionMenuItem: NSMenuItem {
    private let handler: () -> Void

    init(title: String, handler: @escaping () -> Void) {
        self.handler = handler
        super.init(title: title, action: #selector(fire), keyEquivalent: "")
        target = self
    }

    required init(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    @objc private func fire() { handler() }
}
