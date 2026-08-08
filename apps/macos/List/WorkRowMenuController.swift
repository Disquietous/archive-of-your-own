import AppKit
import SwiftUI

/// The work-row context menu shared by every table of works (library list
/// pane, search results). Owns the standard items and their actions; hosts
/// append context-specific tail items via `workItem`.
@MainActor
final class WorkRowMenuController: NSObject {
    private let theme: AppTheme
    private let appState: AppState
    private let model: MacAppModel
    /// Resolves a table row to its work at click time.
    private let workForRow: (Int) -> Work?
    /// Hosts the bookmark-editor sheet.
    private unowned let presenter: NSViewController

    init(theme: AppTheme, appState: AppState, model: MacAppModel,
         presenter: NSViewController, workForRow: @escaping (Int) -> Work?) {
        self.theme = theme
        self.appState = appState
        self.model = model
        self.presenter = presenter
        self.workForRow = workForRow
    }

    /// Append the standard work items to `menu`. `includeEpubExport` adds
    /// the list pane's "Export as EPUB…" item for downloaded works.
    func addStandardItems(to menu: NSMenu, for work: Work, row: Int,
                          includeEpubExport: Bool = false) {
        let started = (appState.progressMap[work.id]?.chapter ?? 0) > 0

        menu.addItem(item("Open", #selector(menuOpenWork(_:)), row))
        menu.addItem(item(started ? "Continue Reading" : "Start Reading",
                          #selector(menuReadWork(_:)), row))
        menu.addItem(.separator())
        menu.addItem(item(appState.bookmarkedWorkIDs.contains(work.id) ? "Remove Bookmark" : "Bookmark",
                          #selector(menuToggleBookmark(_:)), row))
        if appState.bookmarkedWorkIDs.contains(work.id) {
            menu.addItem(item("Edit Bookmark…", #selector(menuEditBookmark(_:)), row))
        }
        menu.addItem(item(appState.downloadedWorkIDs.contains(work.id) ? "Delete Download" : "Download for Offline",
                          #selector(menuToggleDownload(_:)), row))
        if UInt64(work.id) != nil {
            menu.addItem(item("Copy AO3 Link", #selector(menuCopyWorkLink(_:)), row))
        }
        if includeEpubExport && appState.downloadedWorkIDs.contains(work.id) {
            menu.addItem(item("Export as EPUB…", #selector(menuExportEpub(_:)), row))
        }
        if UInt64(work.id) != nil {
            menu.addItem(readingListMenuItem(for: work, row: row))
        }
    }

    /// A context-specific item whose action runs `handler` on the clicked
    /// work — for the hosts' tail items (remove from list/section).
    func workItem(_ title: String, row: Int, handler: @escaping (Work) -> Void) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: #selector(runWorkAction(_:)), keyEquivalent: "")
        item.target = self
        item.representedObject = WorkAction(row: row, handler: handler)
        return item
    }

    // MARK: - Internals

    private final class WorkAction {
        let row: Int
        let handler: (Work) -> Void
        init(row: Int, handler: @escaping (Work) -> Void) {
            self.row = row
            self.handler = handler
        }
    }

    /// "Add to Reading List" ▸ every list with a membership checkmark
    /// (clicking toggles), plus "New Reading List…".
    private func readingListMenuItem(for work: Work, row: Int) -> NSMenuItem {
        let parent = NSMenuItem(title: "Add to Reading List", action: nil, keyEquivalent: "")
        let submenu = NSMenu()
        let workId = UInt64(work.id)
        for list in appState.readingLists {
            let member = workId.map { appState.bridge.getReadingListItems(list.id).contains($0) } ?? false
            let entry = item(list.name, #selector(menuToggleReadingList(_:)), row)
            entry.representedObject = NSNumber(value: list.id)
            entry.state = member ? .on : .off
            submenu.addItem(entry)
        }
        if !appState.readingLists.isEmpty {
            submenu.addItem(.separator())
        }
        submenu.addItem(item("New Reading List…", #selector(menuAddToNewReadingList(_:)), row))
        parent.submenu = submenu
        return parent
    }

    private func item(_ title: String, _ action: Selector, _ row: Int) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        item.tag = row
        return item
    }

    private func clickedWork(_ sender: NSMenuItem) -> Work? {
        workForRow(sender.tag)
    }

    // MARK: - Actions

    @objc private func runWorkAction(_ sender: NSMenuItem) {
        guard let action = sender.representedObject as? WorkAction,
              let work = workForRow(action.row) else { return }
        action.handler(work)
    }

    @objc private func menuOpenWork(_ sender: NSMenuItem) {
        guard let work = clickedWork(sender) else { return }
        model.selectWork(work.id)
    }

    @objc private func menuReadWork(_ sender: NSMenuItem) {
        guard let work = clickedWork(sender) else { return }
        let chapter = max(0, (appState.progressMap[work.id]?.chapter ?? 1) - 1)
        model.openReader(work.id, chapter: chapter)
    }

    @objc private func menuToggleBookmark(_ sender: NSMenuItem) {
        guard let work = clickedWork(sender) else { return }
        appState.toggleBookmark(work.id)
    }

    @objc private func menuToggleDownload(_ sender: NSMenuItem) {
        guard let work = clickedWork(sender) else { return }
        appState.toggleDownload(work.id)
    }

    @objc private func menuCopyWorkLink(_ sender: NSMenuItem) {
        guard let work = clickedWork(sender), UInt64(work.id) != nil else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString("https://archiveofourown.org/works/\(work.id)", forType: .string)
    }

    @objc private func menuExportEpub(_ sender: NSMenuItem) {
        guard let work = clickedWork(sender) else { return }
        EpubExporter.export(work: work, appState: appState)
    }

    @objc private func menuEditBookmark(_ sender: NSMenuItem) {
        guard let work = clickedWork(sender) else { return }
        var dismissRef: () -> Void = {}
        let view = MacBookmarkEditView(theme: theme, appState: appState,
                                       workID: work.id, workTitle: work.title,
                                       onClose: { dismissRef() })
        let hosting = NSHostingController(rootView: view)
        dismissRef = { [weak presenter, weak hosting] in
            if let hosting { presenter?.dismiss(hosting) }
        }
        presenter.presentAsSheet(hosting)
    }

    @objc private func menuToggleReadingList(_ sender: NSMenuItem) {
        guard let work = clickedWork(sender),
              let listId = (sender.representedObject as? NSNumber)?.int64Value else { return }
        if sender.state == .on {
            appState.removeFromReadingList(listId, workId: work.id)
        } else {
            appState.addToReadingList(listId, workId: work.id)
        }
    }

    @objc private func menuAddToNewReadingList(_ sender: NSMenuItem) {
        guard let work = clickedWork(sender) else { return }
        let alert = NSAlert()
        alert.messageText = "New Reading List"
        alert.informativeText = "“\(work.title)” will be added to the new list."
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
            appState.addToReadingList(listId, workId: work.id)
        }
    }
}
