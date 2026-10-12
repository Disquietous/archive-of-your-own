import AppKit
import SwiftUI

extension ReadPaneViewController {
    // MARK: - Mark all as read (author works lists)

    /// Header toggle for an author's works list: flags every listed work
    /// as finished, or clears the flag when they all already are. Both
    /// directions are confirmed first — the flag is manual-only, so a
    /// stray click must not rewrite a whole list.
    func markAllReadButton(works: [Work]) -> ToolButton {
        markAllReadWorks = works
        let button = markAllReadBtn ?? ToolButton(theme: theme, symbol: "checkmark.circle",
                                                  tooltip: "Mark all as read") { [weak self] in
            self?.confirmMarkAllRead()
        }
        markAllReadBtn = button
        let allFinished = !works.isEmpty && works.allSatisfy { appState.finishedWorkIDs.contains($0.id) }
        button.setSymbol(allFinished ? "checkmark.circle.fill" : "checkmark.circle")
        button.tintOverride = allFinished ? theme.nsSage : nil
        button.isOn = allFinished
        button.isEnabled = !works.isEmpty
        button.toolTip = allFinished
            ? "All \(works.count) works are marked as read — click to unmark all"
            : "Mark all \(works.count) works in this list as read"
        return button
    }

    func confirmMarkAllRead() {
        let works = markAllReadWorks
        guard !works.isEmpty else { return }
        let allFinished = works.allSatisfy { appState.finishedWorkIDs.contains($0.id) }
        let count = works.count == 1 ? "1 work" : "\(works.count) works"
        let alert = NSAlert()
        alert.alertStyle = .warning
        if allFinished {
            alert.messageText = "Unmark all as read?"
            alert.informativeText = "This clears the finished-reading flag on all \(count) in this list."
            alert.addButton(withTitle: "Unmark All")
        } else {
            alert.messageText = "Mark all as read?"
            alert.informativeText = "This flags all \(count) in this list as finished reading."
            alert.addButton(withTitle: "Mark All as Read")
        }
        alert.addButton(withTitle: "Cancel")
        let apply = { [weak self] (response: NSApplication.ModalResponse) in
            guard let self, response == .alertFirstButtonReturn else { return }
            appState.setFinished(works.map(\.id), finished: !allFinished)
        }
        if let window = view.window {
            alert.beginSheetModal(for: window, completionHandler: apply)
        } else {
            apply(alert.runModal())
        }
    }

    // MARK: - Actions

    func toggleSettingsPopover() {
        ReaderToolbarActions.presentReadingSettings(theme: theme, presenter: self)
    }

    /// Move the selected work into its own window. While reading, the
    /// window picks up exactly where the pane was (chapter + anchored
    /// line) and the pane goes back to the details — a move, not a copy,
    /// so the work still has exactly one reader.
    func detachToWindow() {
        guard let id = model.selectedWorkID else { return }
        if model.readerOpen {
            readerController.flushPendingPersist()
            let chapter = readerController.chapterIndex
            let pos = readerController.anchorOffset ?? 0
            model.closeReader()
            model.windows.open(id, chapter: chapter, at: pos)
        } else {
            let chapter = max(0, (appState.progressMap[id]?.chapter ?? 1) - 1)
            model.windows.open(id, chapter: chapter, at: nil)
        }
    }

    @objc func exitImmersive() {
        model.exitImmersive()
    }

    func toggleChaptersPopover() {
        if let popover = chaptersPopover, popover.isShown {
            popover.close()
            chaptersPopover = nil
            return
        }
        guard let work = model.selectedWork else { return }
        chaptersPopover = ReaderToolbarActions.chaptersPopover(
            theme: theme, appState: appState, session: model.paneReader,
            workID: work.id, anchor: chaptersButton) { [weak self] in
                self?.chaptersPopover?.close()
                self?.chaptersPopover = nil
            }
    }

    func toggleReadingListPopover() {
        if let popover = readingListPopover, popover.isShown {
            popover.close()
            readingListPopover = nil
            return
        }
        guard let work = model.selectedWork else { return }
        let popover = NSPopover()
        popover.behavior = .transient
        popover.contentViewController = NSHostingController(
            rootView: ReadingListPopover(theme: theme, appState: appState, work: work))
        popover.show(relativeTo: readingListButton.bounds, of: readingListButton, preferredEdge: .maxY)
        readingListPopover = popover
    }

    /// Comments for the whole work (detail-mode toolbar), as a sheet.
    func showWorkComments() {
        guard let work = model.selectedWork else { return }
        ReaderToolbarActions.presentWorkComments(theme: theme, appState: appState, work: work, presenter: self)
    }

    func showBookmarkEditSheet() {
        guard let work = model.selectedWork else { return }
        ReaderToolbarActions.presentBookmarkEdit(theme: theme, appState: appState, work: work, presenter: self)
    }

    /// Comments for the chapter currently open in the reader, as a sheet.
    func showChapterComments() {
        guard let work = model.selectedWork else { return }
        ReaderToolbarActions.presentChapterComments(theme: theme, appState: appState, work: work,
                                                    chapterIndex: model.readerChapter, presenter: self)
    }
}
