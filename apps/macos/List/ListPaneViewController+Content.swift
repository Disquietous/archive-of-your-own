import AppKit
import SwiftUI

// MARK: - Content swapping

extension ListPaneViewController {
    func showWorksContent(section: MacAppModel.Section, header: NSView?, overlay: AnyView?) {
        variantHost?.removeFromSuperview()
        variantHost = nil

        // Swap the pane header (tag chips for browse).
        if chipsHost !== header {
            chipsHost?.removeFromSuperview()
        }
        if let header, header.superview == nil {
            contentStack.insertArrangedSubview(header, at: 0)
            header.widthAnchor.constraint(equalTo: contentStack.widthAnchor).isActive = true
        }

        if scrollView.superview == nil {
            contentStack.addArrangedSubview(scrollView)
            scrollView.widthAnchor.constraint(equalTo: contentStack.widthAnchor).isActive = true
        }

        overlayHost?.removeFromSuperview()
        overlayHost = nil
        if let overlay {
            // Sibling of the scroll view, never inside it — NSScrollView tiles
            // its own subviews and scrambles constraint-based placement.
            let host = NSHostingView(rootView: overlay)
            host.translatesAutoresizingMaskIntoConstraints = false
            view.addSubview(host)
            NSLayoutConstraint.activate([
                host.centerXAnchor.constraint(equalTo: scrollView.centerXAnchor),
                host.centerYAnchor.constraint(equalTo: scrollView.centerYAnchor),
                host.widthAnchor.constraint(lessThanOrEqualTo: scrollView.widthAnchor),
            ])
            overlayHost = host
        }
        let sectionChanged = renderedSection != section
        // Content-aware row signature: a What's-New check or forced refresh
        // can change a work's dates/counts without changing which rows are
        // shown — those edits must repaint, not just selection state.
        let ids = works.map { "\($0.id)|\($0.updated)|\($0.chapterCount)|\($0.words)" }
        if sectionChanged || ids != renderedWorkIDs {
            tableView.reloadData()
        } else {
            // Same rows — only move the selection highlight and bookmark
            // indicator. Reloading here replaces every cell and makes
            // expand/collapse look like a flash. (Reading bookmarkedWorkIDs
            // also re-renders the moment a bookmark toggles.)
            let bookmarked = appState.bookmarkedWorkIDs
            tableView.enumerateAvailableRowViews { [weak self] _, row in
                guard let self, row < works.count,
                      let cell = tableView.view(atColumn: 0, row: row, makeIfNecessary: false) as? WorkRowCellView
                else { return }
                cell.setSelected(works[row].id == model.selectedWorkID)
                cell.setBookmarked(bookmarked.contains(works[row].id))
            }
        }
        renderedWorkIDs = ids
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

    func showSubscriptionsContent(section: MacAppModel.Section, overlay: AnyView?) {
        variantHost?.removeFromSuperview()
        variantHost = nil
        chipsHost?.removeFromSuperview()

        if scrollView.superview == nil {
            contentStack.addArrangedSubview(scrollView)
            scrollView.widthAnchor.constraint(equalTo: contentStack.widthAnchor).isActive = true
        }

        overlayHost?.removeFromSuperview()
        overlayHost = nil
        if let overlay {
            let host = NSHostingView(rootView: overlay)
            host.translatesAutoresizingMaskIntoConstraints = false
            view.addSubview(host)
            NSLayoutConstraint.activate([
                host.centerXAnchor.constraint(equalTo: scrollView.centerXAnchor),
                host.centerYAnchor.constraint(equalTo: scrollView.centerYAnchor),
                host.widthAnchor.constraint(lessThanOrEqualTo: scrollView.widthAnchor),
            ])
            overlayHost = host
        }

        // Read the drill-in identity and loading state on EVERY render path,
        // not just the same-rows branch: the reload path's cell configuration
        // happens lazily outside this tracked closure, so without these reads
        // a reload render left the relay blind to selection changes — the
        // highlight then waited for cells to scroll off-screen and re-make.
        let activeID = model.subscriptionWorksSubId
        let activeType = model.subscriptionWorksSubType
        let loadingID = model.loadingSubscriptionID

        let sectionChanged = renderedSection != section
        let ids = displayedSubscriptions.map(\.id)
        if sectionChanged || ids != renderedSubscriptionIDs {
            tableView.reloadData()
        } else {
            // Same rows — reconfigure the visible cells so the selection
            // highlight and "Fetching works…" state move immediately.
            tableView.enumerateAvailableRowViews { [weak self] _, row in
                guard let self, row < displayedSubscriptions.count,
                      let cell = tableView.view(atColumn: 0, row: row, makeIfNecessary: false) as? SubscriptionRowCellView
                else { return }
                let sub = displayedSubscriptions[row]
                cell.configure(with: sub,
                               isLoading: loadingID == sub.id,
                               isActive: activeID == sub.id && activeType == normalizedSubType(sub),
                               lastChecked: displayedLastChecked["\(sub.subType):\(sub.id)"])
            }
        }
        renderedSubscriptionIDs = ids
        renderedWorkIDs = []
        if sectionChanged {
            tableView.scroll(.zero)
        }
        tableView.deselectAll(nil)
    }

    /// Reading-list rows in the shared table — the same shape as
    /// showSubscriptionsContent: reload when the row set changes, otherwise
    /// reconfigure visible cells in place so the active highlight moves.
    func showReadingListsContent(section: MacAppModel.Section, overlay: AnyView?) {
        variantHost?.removeFromSuperview()
        variantHost = nil
        chipsHost?.removeFromSuperview()

        if scrollView.superview == nil {
            contentStack.addArrangedSubview(scrollView)
            scrollView.widthAnchor.constraint(equalTo: contentStack.widthAnchor).isActive = true
        }

        overlayHost?.removeFromSuperview()
        overlayHost = nil
        if let overlay {
            let host = NSHostingView(rootView: overlay)
            host.translatesAutoresizingMaskIntoConstraints = false
            view.addSubview(host)
            NSLayoutConstraint.activate([
                host.centerXAnchor.constraint(equalTo: scrollView.centerXAnchor),
                host.centerYAnchor.constraint(equalTo: scrollView.centerYAnchor),
                host.widthAnchor.constraint(lessThanOrEqualTo: scrollView.widthAnchor),
            ])
            overlayHost = host
        }

        // Read on every render path so the relay tracks selection changes
        // (see showSubscriptionsContent).
        let activeID = model.selectedReadingListID

        let sectionChanged = renderedSection != section
        let ids = displayedReadingLists.map(\.id)
        if sectionChanged || ids != renderedReadingListIDs {
            tableView.reloadData()
        } else {
            tableView.enumerateAvailableRowViews { [weak self] _, row in
                guard let self, row < displayedReadingLists.count,
                      let cell = tableView.view(atColumn: 0, row: row, makeIfNecessary: false) as? ReadingListRowCellView
                else { return }
                let list = displayedReadingLists[row]
                cell.configure(name: list.name,
                               workCount: appState.worksInReadingList(list.id).count,
                               isActive: activeID == list.id)
            }
        }
        renderedReadingListIDs = ids
        renderedWorkIDs = []
        renderedSubscriptionIDs = []
        if sectionChanged {
            tableView.scroll(.zero)
        }
        tableView.deselectAll(nil)
    }

    /// "+" toolbar action: name a new list, then open it.
    func createReadingList() {
        let alert = NSAlert()
        alert.messageText = "New Reading List"
        alert.informativeText = "Add works to it from any work's right-click menu."
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
        field.placeholderString = "Name"
        alert.accessoryView = field
        alert.window.initialFirstResponder = field
        alert.addButton(withTitle: "Create")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let name = field.stringValue.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return }
        let listId = appState.createReadingList(name)
        if listId >= 0 {
            model.goReadingList(listId)
        }
    }

    func showVariant(_ content: some View, section: MacAppModel.Section) {
        chipsHost?.removeFromSuperview()
        scrollView.removeFromSuperview()
        overlayHost?.removeFromSuperview()
        overlayHost = nil
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
}
