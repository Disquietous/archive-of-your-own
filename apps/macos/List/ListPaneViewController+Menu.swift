import AppKit

// MARK: - Row context menu

extension ListPaneViewController: NSMenuDelegate {
    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let row = tableView.clickedRow
        guard row >= 0 else { return }

        if isShowingSubscriptionList {
            guard row < displayedSubscriptions.count else { return }
            let sub = displayedSubscriptions[row]
            let type = sub.subType.lowercased()
            if type.contains("author") || type.contains("user") || type.contains("series") {
                menu.addItem(menuItem("Show Works", #selector(menuShowSubscriptionWorks(_:)), row))
            }
            menu.addItem(menuItem("Copy AO3 Link", #selector(menuCopySubscriptionLink(_:)), row))
            return
        }

        if isShowingReadingLists {
            guard row < displayedReadingLists.count else { return }
            menu.addItem(menuItem("Show Works", #selector(menuShowReadingList(_:)), row))
            menu.addItem(.separator())
            menu.addItem(menuItem("Rename…", #selector(menuRenameReadingList(_:)), row))
            menu.addItem(menuItem("Delete Reading List", #selector(menuDeleteReadingList(_:)), row))
            return
        }

        guard row < works.count else { return }
        let work = works[row]

        workRowMenu.addStandardItems(to: menu, for: work, row: row, includeEpubExport: true)

        // Section-specific destructive action (the swipe action's menu twin).
        switch model.section {
        case .reading:
            menu.addItem(.separator())
            menu.addItem(workRowMenu.workItem("Remove from Currently Reading", row: row) { [weak self] work in
                self?.model.removeFromCurrentlyReading(work.id)
            })
        case .whatsNew:
            menu.addItem(.separator())
            menu.addItem(workRowMenu.workItem("Remove from What’s New", row: row) { [weak self] work in
                self?.appState.removeNewWork(work.id)
            })
        default:
            break
        }
    }

    private func menuItem(_ title: String, _ action: Selector, _ row: Int) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        item.tag = row
        return item
    }

    @objc private func menuShowReadingList(_ sender: NSMenuItem) {
        guard sender.tag >= 0, sender.tag < displayedReadingLists.count else { return }
        model.goReadingList(displayedReadingLists[sender.tag].id)
    }

    @objc private func menuRenameReadingList(_ sender: NSMenuItem) {
        guard sender.tag >= 0, sender.tag < displayedReadingLists.count else { return }
        let list = displayedReadingLists[sender.tag]
        let alert = NSAlert()
        alert.messageText = "Rename Reading List"
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
        field.stringValue = list.name
        alert.accessoryView = field
        alert.window.initialFirstResponder = field
        alert.addButton(withTitle: "Rename")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let name = field.stringValue.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return }
        appState.renameReadingList(list.id, name: name)
    }

    @objc private func menuDeleteReadingList(_ sender: NSMenuItem) {
        guard sender.tag >= 0, sender.tag < displayedReadingLists.count else { return }
        let list = displayedReadingLists[sender.tag]
        let alert = NSAlert()
        alert.messageText = "Delete “\(list.name)”?"
        alert.informativeText = "The list is removed. The works themselves stay in your library."
        alert.addButton(withTitle: "Delete")
        alert.addButton(withTitle: "Cancel")
        alert.buttons.first?.hasDestructiveAction = true
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        if model.selectedReadingListID == list.id {
            model.closeReadingList()
        }
        appState.deleteReadingList(list.id)
    }

    @objc private func menuShowSubscriptionWorks(_ sender: NSMenuItem) {
        guard sender.tag >= 0, sender.tag < displayedSubscriptions.count else { return }
        let sub = displayedSubscriptions[sender.tag]
        model.openSubscriptionAuthorWorks(subscriptionID: sub.id, author: sub.name,
                                          subType: normalizedSubType(sub))
    }

    /// The drill-in/cache key for a subscription ("author" or "series").
    func normalizedSubType(_ sub: USubscription) -> String {
        sub.subType.lowercased().contains("series") ? "series" : "author"
    }

    /// Star button on the search toolbar — names and saves the current criteria.
    func saveSearchButton() -> ToolButton {
        ToolButton(theme: theme, symbol: "star", tooltip: "Save this search") { [weak self] in
            guard let self else { return }
            let alert = NSAlert()
            alert.messageText = "Save Search"
            alert.informativeText = "The current criteria will appear under Saved Searches in the sidebar."
            let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
            field.placeholderString = "Name"
            field.stringValue = model.search.queryText
            alert.accessoryView = field
            alert.addButton(withTitle: "Save")
            alert.addButton(withTitle: "Cancel")
            alert.window.initialFirstResponder = field
            guard alert.runModal() == .alertFirstButtonReturn else { return }
            let name = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty else { return }
            model.search.saveCurrentSearch(named: name, appState: appState)
        }
    }

    @objc private func menuCopySubscriptionLink(_ sender: NSMenuItem) {
        guard sender.tag >= 0, sender.tag < displayedSubscriptions.count else { return }
        let sub = displayedSubscriptions[sender.tag]
        let type = sub.subType.lowercased()
        let url: String
        if type.contains("author") || type.contains("user") {
            url = "https://archiveofourown.org/users/\(sub.id)"
        } else if type.contains("series") {
            url = "https://archiveofourown.org/series/\(sub.id)"
        } else {
            url = "https://archiveofourown.org/works/\(sub.id)"
        }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(url, forType: .string)
    }
}
