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

    func showBookmarkEditSheet() {
        guard let work = model.selectedWork else { return }
        ReaderToolbarActions.presentBookmarkEdit(theme: theme, appState: appState, work: work, presenter: self)
    }

    /// Links, sign-in and toolbar state for the Discussion panel.
    func configureDiscussion() {
        discussion.actions = DiscussionActions(
            openAuthor: { [weak self] name in self?.model.openAuthorProfile(name) },
            openURL: { [weak self] url in
                guard let self else { return }
                if model.openAO3URL(url.absoluteString) != nil {
                    ExternalLinkOpener.open(url, bridge: appState.bridge)
                }
            })
        discussion.onSignIn = { [weak self] in self?.model.goSection(.settings) }
        discussion.onStateChange = { [weak self] in
            guard let self else { return }
            let tint = discussion.isOpen ? theme.nsAccent : nil
            commentsButton.tintOverride = tint
            workCommentsButton.tintOverride = tint
        }
        readerController.onOpenDiscussion = { [weak self] in
            self?.discussion.setOpen(true, focusComposer: true)
        }
    }

    /// Point the Discussion panel at what the pane now shows: the work's
    /// comments in detail mode, the reader's chapter while reading (it
    /// follows chapter changes); unavailable in every other mode.
    func updateDiscussion(for mode: Mode, from previous: Mode?) {
        switch mode {
        case .detail(let workID):
            discussion.isAvailable = true
            discussion.model.showWholeWork(workID: workID)
        case .reading(let workID, let chapter):
            discussion.isAvailable = true
            if case .reading = previous {
                discussion.model.follow(workID: workID, chapterIndex: chapter)
            } else {
                discussion.model.showChapter(workID: workID, chapterIndex: chapter)
            }
        default:
            discussion.model.flushDraft()
            discussion.isAvailable = false
        }
    }
}
