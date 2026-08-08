import AppKit
import SwiftUI

// MARK: - Toolbar buttons

extension ListPaneViewController {
    func eyeToggleButton() -> ToolButton {
        let eye = eyeButton ?? ToolButton(theme: theme, symbol: "eye", tooltip: "Hide explicit") { [weak self] in
            self?.model.hideExplicit.toggle()
        }
        eyeButton = eye
        eye.isOn = model.hideExplicit
        eye.setSymbol(model.hideExplicit ? "eye.slash" : "eye")
        return eye
    }

    func browseRefreshButton() -> ToolButton {
        let button = refreshButton ?? ToolButton(theme: theme, symbol: "arrow.clockwise", tooltip: "Refresh") { [weak self] in
            guard let self else { return }
            Task { await self.appState.browseLatestWorks(force: true) }
        }
        refreshButton = button
        return button
    }

    func searchGoButton() -> ToolButton {
        let button = searchButton ?? ToolButton(theme: theme, symbol: "magnifyingglass", tooltip: "Search") { [weak self] in
            guard let self else { return }
            model.search.performSearch(appState)
        }
        searchButton = button
        button.isOn = true
        return button
    }

    func reloadFieldsButton() -> ToolButton {
        let button = loadMoreButton ?? ToolButton(theme: theme, symbol: "arrow.clockwise", tooltip: "Reload search criteria from AO3") { [weak self] in
            guard let self else { return }
            Task { await self.model.search.scrapeForm(self.appState) }
        }
        loadMoreButton = button
        return button
    }

    func removeAllReadingButton() -> ToolButton {
        let button = removeAllButton ?? ToolButton(theme: theme, symbol: "trash", tooltip: "Remove all") { [weak self] in
            self?.confirmRemoveAllReading()
        }
        removeAllButton = button
        return button
    }

    func clearHistoryButton() -> ToolButton {
        let button = clearHistoryBtn ?? ToolButton(theme: theme, symbol: "trash", tooltip: "Clear history") { [weak self] in
            self?.confirmClearHistory()
        }
        clearHistoryBtn = button
        return button
    }

    private func confirmClearHistory() {
        guard let window = view.window else { return }
        let alert = NSAlert()
        alert.messageText = "Clear Reading History?"
        alert.informativeText = "This removes every entry from your reading history. Reading positions, bookmarks, and downloads are not affected."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Clear History")
        alert.addButton(withTitle: "Cancel")
        alert.buttons.first?.hasDestructiveAction = true
        alert.beginSheetModal(for: window) { [weak self] response in
            guard let self, response == .alertFirstButtonReturn else { return }
            appState.clearHistory()
        }
    }

    private func confirmRemoveAllReading() {
        guard let window = view.window else { return }
        let alert = NSAlert()
        alert.messageText = "Remove All from Currently Reading?"
        alert.informativeText = "This clears the saved reading position for every work in the list. The works stay in your history, bookmarks, and downloads."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Remove All")
        alert.addButton(withTitle: "Cancel")
        alert.buttons.first?.hasDestructiveAction = true
        alert.beginSheetModal(for: window) { [weak self] response in
            guard let self, response == .alertFirstButtonReturn else { return }
            model.removeAllCurrentlyReading()
        }
    }

    func inboxToolbarButtons() -> [NSView] {
        let prev = inboxPrevButton ?? ToolButton(theme: theme, symbol: "chevron.left", tooltip: "Previous page") { [weak self] in
            guard let self else { return }
            let page = self.appState.inboxPage
            guard page > 1 else { return }
            self.appState.loadCachedInbox(page: page - 1)
        }
        inboxPrevButton = prev
        prev.isEnabled = appState.inboxPage > 1

        let next = inboxNextButton ?? ToolButton(theme: theme, symbol: "chevron.right", tooltip: "Next page") { [weak self] in
            guard let self else { return }
            guard self.appState.inboxHasMore else { return }
            self.appState.loadCachedInbox(page: self.appState.inboxPage + 1)
        }
        inboxNextButton = next
        next.isEnabled = appState.inboxHasMore

        let container: NSView
        if let existing = inboxPageContainer {
            container = existing
        } else {
            let label = NSTextField(labelWithString: "Page")
            label.font = MacFont.ui(11, weight: .medium)
            label.textColor = theme.nsInk3
            label.translatesAutoresizingMaskIntoConstraints = false

            let field = NSTextField()
            field.font = MacFont.ui(12, weight: .medium)
            field.alignment = .center
            field.isBordered = true
            field.isBezeled = true
            field.bezelStyle = .roundedBezel
            field.translatesAutoresizingMaskIntoConstraints = false
            field.target = self
            field.action = #selector(inboxPageFieldCommitted)
            NSLayoutConstraint.activate([
                field.widthAnchor.constraint(equalToConstant: 36),
                field.heightAnchor.constraint(equalToConstant: 22),
            ])
            inboxPageField = field

            let stack = NSStackView(views: [label, field])
            stack.orientation = .horizontal
            stack.spacing = 4
            stack.alignment = .centerY
            stack.translatesAutoresizingMaskIntoConstraints = false
            inboxPageContainer = stack
            container = stack
        }

        inboxPageField?.stringValue = "\(appState.inboxPage)"

        let refresh = ToolButton(theme: theme, symbol: "arrow.clockwise", tooltip: "Check for new messages") { [weak self] in
            guard let self else { return }
            Task { await self.appState.checkInbox() }
        }

        return [prev, container, next, refresh]
    }

    @objc private func inboxPageFieldCommitted() {
        guard let text = inboxPageField?.stringValue,
              let page = UInt32(text), page >= 1 else {
            inboxPageField?.stringValue = "\(appState.inboxPage)"
            return
        }
        appState.loadCachedInbox(page: page)
    }

    // MARK: - Per-section filter popover

    /// Toolbar button opening the section's tailored filter dialog; lit
    /// (accent fill) while a filter is active.
    func filterButton(key: String, active: Bool, content: @escaping () -> AnyView) -> ToolButton {
        if let existing = filterButtons[key] {
            existing.isOn = active
            return existing
        }
        var anchor: ToolButton!
        let button = ToolButton(theme: theme, symbol: "line.3.horizontal.decrease.circle",
                                tooltip: "Filter this list") { [weak self] in
            guard let self, let anchor else { return }
            if let popover = filterPopover, popover.isShown {
                popover.close()
                filterPopover = nil
                return
            }
            let popover = NSPopover()
            popover.behavior = .transient
            let host = NSHostingController(rootView: content())
            popover.contentViewController = host
            // Size the popover to the SwiftUI content BEFORE showing — an
            // unsized hosting controller makes NSPopover pick an arbitrary
            // frame and misplace the dialog relative to its anchor.
            host.view.layoutSubtreeIfNeeded()
            popover.contentSize = host.view.fittingSize
            popover.show(relativeTo: anchor.bounds, of: anchor, preferredEdge: .maxY)
            filterPopover = popover
        }
        button.isOn = active
        anchor = button
        filterButtons[key] = button
        return button
    }

    func worksFilterButton(for section: MacAppModel.Section) -> ToolButton {
        filterButton(key: "works-\(section)",
                     active: model.workListFilter(for: section).isActive) { [theme, model] in
            AnyView(WorkListFilterView(theme: theme, model: model, section: section))
        }
    }
}
