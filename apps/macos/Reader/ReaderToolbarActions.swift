import AppKit
import SwiftUI

/// The reader toolbar's sheets and popovers, shared by the reading pane
/// and the work windows so both hosts present exactly the same UI.
/// `presenter` is the view controller that owns the sheet.
@MainActor
enum ReaderToolbarActions {
    /// Reading settings as a window sheet — a popover this wide would hang
    /// outside the window's visual bounds when anchored to the toolbar.
    static func presentReadingSettings(theme: AppTheme, presenter: NSViewController) {
        guard presenter.presentedViewControllers?.isEmpty != false else { return }
        presentSheet(on: presenter) { dismiss in
            AnyView(ReadingSettingsView(theme: theme, onClose: dismiss))
        }
    }

    /// Comments for the whole work.
    static func presentWorkComments(theme: AppTheme, appState: AppState, work: Work,
                                    presenter: NSViewController) {
        presentSheet(on: presenter) { dismiss in
            AnyView(MacCommentsView(theme: theme, appState: appState,
                                    workID: work.id, chapterID: nil,
                                    title: work.title, subtitle: nil,
                                    onClose: dismiss))
        }
    }

    /// Comments for one chapter (0-based `chapterIndex`) of the work.
    static func presentChapterComments(theme: AppTheme, appState: AppState, work: Work,
                                       chapterIndex: Int, presenter: NSViewController) {
        var chapterId: UInt64?
        if let chapters = appState.chaptersForWork(work.id), chapterIndex < chapters.count {
            let id = chapters[chapterIndex].chapterId
            chapterId = id > 0 ? UInt64(id) : nil
        }
        presentSheet(on: presenter) { dismiss in
            AnyView(MacCommentsView(theme: theme, appState: appState,
                                    workID: work.id, chapterID: chapterId,
                                    title: work.title, subtitle: "Chapter \(chapterIndex + 1)",
                                    onClose: dismiss))
        }
    }

    static func presentBookmarkEdit(theme: AppTheme, appState: AppState, work: Work,
                                    presenter: NSViewController) {
        presentSheet(on: presenter) { dismiss in
            AnyView(MacBookmarkEditView(theme: theme, appState: appState,
                                        workID: work.id, workTitle: work.title,
                                        onClose: dismiss))
        }
    }

    /// The chapter-list popover for a reader session, anchored below
    /// `anchor`. The caller owns the returned popover (to toggle it closed).
    static func chaptersPopover(theme: AppTheme, appState: AppState, session: ReaderSession,
                                workID: String, anchor: NSView,
                                onSelect: @escaping () -> Void) -> NSPopover {
        let popover = NSPopover()
        popover.behavior = .transient
        popover.contentViewController = NSHostingController(
            rootView: ChapterListPopover(theme: theme, appState: appState, session: session,
                                         workID: workID, onSelect: onSelect))
        popover.show(relativeTo: anchor.bounds, of: anchor, preferredEdge: .maxY)
        return popover
    }

    /// Host a SwiftUI view as a sheet whose own close control dismisses it.
    private static func presentSheet(on presenter: NSViewController,
                                     _ content: (@escaping () -> Void) -> AnyView) {
        var dismissRef: () -> Void = {}
        let hosting = NSHostingController(rootView: content { dismissRef() })
        dismissRef = { [weak presenter, weak hosting] in
            if let hosting { presenter?.dismiss(hosting) }
        }
        presenter.presentAsSheet(hosting)
    }
}
