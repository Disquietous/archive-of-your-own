import Foundation
import Observation

/// The navigation state of one reader — the pane reader or one work
/// window. `MacAppModel` used to hold this for the (single) pane reader;
/// pulling it out lets any number of `ReaderViewController`s run at once
/// without fighting over one chapter / resume position / return point.
///
/// Everything here is main-actor UI memory. Progress persistence, history
/// and the chapter cache stay in `AppState`, shared by every reader.
@Observable
@MainActor
final class ReaderSession {
    /// Where the reader was before the last chapter change — UI memory
    /// only, never persisted. Backs the footer's "return to previous
    /// position" control; empty on a fresh open and cleared when the work
    /// is left.
    struct ReturnPoint: Equatable {
        /// 0-based chapter index.
        let chapter: Int
        /// Character offset within that chapter.
        let pos: Int
    }

    /// The work this reader is showing; nil while closed.
    private(set) var workID: String?
    /// 0-based chapter index.
    var chapter = 0
    /// Saved position (character offset) for the chapter being opened;
    /// consumed by the reader on its first successful render.
    var resumePos = 0
    var returnPoint: ReturnPoint?
    /// Full-width reading layout. In the pane this also hides the sidebar
    /// and list and follows the user's setting per open; a work window is
    /// immersive reading by definition and stays this way.
    var immersive = false

    enum Layout {
        /// The main window's reading pane.
        case pane
        /// A standalone work window.
        case window
    }

    /// The chapter fetch in flight for this reader, one per session so
    /// each reader's banner shows its own request.
    @ObservationIgnored let chapterFetchOp = TrackedOperation()
    @ObservationIgnored weak var host: ReaderSessionHost?
    /// Installed by the reader view showing this session: runs its
    /// debounced scroll persist now. Lets owners that never see the view
    /// (the window registry moving a work out of the pane) land the last
    /// position before repointing or closing.
    @ObservationIgnored var flushPersist: (() -> Void)?
    /// Installed by the reader view: drops its debounced scroll persist
    /// without writing it (the position it holds is no longer true).
    @ObservationIgnored var cancelPersist: (() -> Void)?
    /// Installed by the reader view: re-land on `pos` within the chapter
    /// it is already showing, as if that position had just been opened.
    @ObservationIgnored var reanchor: ((Int) -> Void)?

    @ObservationIgnored private let appState: AppState
    @ObservationIgnored private let theme: AppTheme
    @ObservationIgnored let layout: Layout

    init(appState: AppState, theme: AppTheme, layout: Layout) {
        self.appState = appState
        self.theme = theme
        self.layout = layout
        immersive = layout == .window
    }

    /// Point the reader at `id` / `chapter`. A chapter change within the
    /// open work remembers where the reader was, so the footer's return
    /// control can take them back. A fresh open starts with no return
    /// point — only this chapter has been seen.
    func open(_ id: String, chapter: Int, at pos: Int? = nil) {
        if workID == id {
            if chapter != self.chapter {
                let stored = appState.progressMap[id]
                stashReturnPoint(chapter: self.chapter,
                                 pos: stored?.chapter == self.chapter + 1 ? stored?.pos ?? 0 : 0)
            }
        } else {
            returnPoint = nil
            // A fresh open lands in the user's preferred reading view;
            // chapter changes inside an open work keep whatever view the
            // reader is already in.
            immersive = layout == .window || theme.fullscreenReading
        }
        // Stash the in-chapter position — the reader consumes this to land
        // back on the anchored line. An explicit `pos` (the return control)
        // wins over the saved progress.
        if let pos {
            resumePos = pos
        } else if let existing = appState.progressMap[id], existing.chapter == chapter + 1 {
            resumePos = existing.pos
        } else {
            resumePos = 0
        }
        aoyoPosLog("openReader work=\(id) ch=\(chapter) existing=\(appState.progressMap[id].map { "ch\($0.chapter)@\($0.pos)" } ?? "nil") stash=\(resumePos)")
        workID = id
        self.chapter = chapter
        appState.pushHistory(id)
        appState.markWorkRead(id)
        // Opening a chapter enrolls the work in Currently Reading immediately —
        // scrolling only refines the position. Re-recording the stashed
        // position keeps the saved place intact until the reader actually
        // moves; a chapter never visited starts at its top.
        appState.setProgress(id, chapter: chapter + 1, pos: resumePos)
    }

    /// Re-open at a remembered place without the side effects of `open`
    /// (history, progress) — the pane's per-section memory restoring what
    /// it was showing, or a work window coming back after unlock. An
    /// explicit `pos` wins over the saved progress.
    func restore(_ id: String, chapter: Int, at pos: Int? = nil) {
        if let pos {
            resumePos = pos
        } else if let progress = appState.progressMap[id], progress.chapter == chapter + 1 {
            resumePos = progress.pos
        } else {
            resumePos = 0
        }
        workID = id
        self.chapter = chapter
    }

    func stashReturnPoint(chapter: Int, pos: Int) {
        returnPoint = ReturnPoint(chapter: chapter, pos: pos)
    }

    func returnToPreviousPosition() {
        guard let id = workID, let point = returnPoint else { return }
        // open stashes the chapter being left, so the control swaps
        // between the two positions rather than consuming itself.
        open(id, chapter: point.chapter, at: point.pos)
    }

    /// Write the reader's pending debounced position now (no-op when no
    /// reader view is attached or nothing is pending).
    func flushPendingPersist() {
        flushPersist?()
    }

    /// The library file was replaced underneath the app: move this reader
    /// to wherever the new library says the work is. The in-memory anchor
    /// and any debounced persist describe the old library and are dropped,
    /// never written. A work the new library isn't reading stays where the
    /// reader is; its next scroll re-enrolls it.
    func reanchorFromStorage() {
        guard let id = workID else { return }
        cancelPersist?()
        guard let progress = appState.progressMap[id] else { return }
        let target = max(0, progress.chapter - 1)
        returnPoint = nil
        if target != chapter {
            // The chapter change re-shows the reader (pane mode / window
            // render both key on it); the stash lands it on the line.
            resumePos = progress.pos
            chapter = target
        } else {
            reanchor?(progress.pos)
        }
        aoyoPosLog("reanchor work=\(id) -> ch\(progress.chapter)@\(progress.pos)")
    }

    /// Reset to closed. Pure state — the host decides what closing looks
    /// like (pane: back to details; window: close the window).
    func close() {
        workID = nil
        immersive = layout == .window
        returnPoint = nil
    }

    // MARK: - Host requests (from the reader view)

    /// The reader wants out (cancelled load, back control).
    func requestClose() {
        host?.readerSessionDidClose(self)
    }

    /// End-of-work "Next work in series".
    func openNextWork(_ id: String) {
        host?.readerSession(self, openNextWork: id)
    }
}

/// What a reader session's owner does when the reader asks to close or
/// to move on to the next work in a series.
@MainActor
protocol ReaderSessionHost: AnyObject {
    func readerSessionDidClose(_ session: ReaderSession)
    func readerSession(_ session: ReaderSession, openNextWork id: String)
}
