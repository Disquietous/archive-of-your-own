import AppKit
import SwiftUI

/// A work in its own window: a slim toolbar row over the same
/// `ReaderViewController` the reading pane uses, driven by its own
/// `ReaderSession` so it never fights the pane (or another window) over
/// chapter, resume position or return point. Created only through
/// `WorkWindowRegistry.open`; closing unregisters it and lets it
/// deallocate so its observation relays stop with it.
///
/// Lives entirely on the main actor like the pane reader — no new threads.
@MainActor
final class WorkWindowController: NSWindowController, NSWindowDelegate {
    private let theme: AppTheme
    private let appState: AppState
    private unowned let model: MacAppModel
    private unowned let registry: WorkWindowRegistry

    let session: ReaderSession
    private let reader: ReaderViewController
    private let content: NSViewController
    private let toolbar: PaneToolbarView
    private let requestProgressOverlay = RequestProgressOverlay()

    private var showInMainButton: ToolButton!
    private var chaptersButton: ToolButton!
    private var settingsButton: ToolButton!
    private var refreshButton: ToolButton!
    private var commentsButton: ToolButton!
    private var bookmarkButton: ToolButton!
    private var chaptersPopover: NSPopover?
    private var keyMonitor: Any?

    /// (work id, chapter) the reader was last pointed at — the relay only
    /// re-shows the reader when this pair changes, exactly like the pane's
    /// `show(mode:)` guard.
    private var renderedKey: (String, Int)?

    /// The work this window shows, for the File menu and the registry.
    var work: Work? {
        session.workID.flatMap { appState.work(byID: $0) }
    }

    /// Where a new window goes: stepped off another work window (a fresh
    /// open), or exactly at a remembered frame (restoring after unlock).
    enum Placement {
        case cascade(from: NSWindow?)
        case frame(NSRect)
    }

    init(theme: AppTheme, appState: AppState, model: MacAppModel, registry: WorkWindowRegistry,
         placement: Placement) {
        self.theme = theme
        self.appState = appState
        self.model = model
        self.registry = registry
        self.session = ReaderSession(appState: appState, theme: theme, layout: .window)
        self.reader = ReaderViewController(theme: theme, appState: appState, session: session)
        self.toolbar = PaneToolbarView(theme: theme)
        self.content = NSViewController()

        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1280, height: 820),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable],
                              backing: .buffered, defer: false)
        window.minSize = NSSize(width: 480, height: 420)
        window.collectionBehavior = [.fullScreenPrimary]
        window.tabbingMode = .disallowed
        super.init(window: window)
        // NSWindowController would otherwise re-position the window on its
        // first show; the frame set below is the one we want.
        shouldCascadeWindows = false
        window.delegate = self
        session.host = self

        buildContent()
        window.contentViewController = content
        // Assigning contentViewController resizes the window to the
        // content view's own (empty) size, so the frame must be applied
        // AFTER it — the same order MainWindowController.apply(gate:) uses.
        switch placement {
        case .cascade(let other):
            // A work window IS immersive reading, so it takes the main window's
            // whole frame — size and place — what immersive reading fills there.
            if let main = Self.mainWindow {
                window.setFrame(main.frame, display: false)
            } else {
                window.center()
            }
            // Another work window is already there: step down-right of it
            // instead of covering it exactly.
            if let other {
                window.cascadeTopLeft(from: NSPoint(x: other.frame.minX, y: other.frame.maxY))
            }
        case .frame(let frame):
            // setFrame constrains to the current screens, so a frame from a
            // display that has since gone comes back on one that is there.
            window.setFrame(frame, display: false)
        }
        NSLog("[WorkWindow] main=%@ new=%@", Self.mainWindow.map { NSStringFromRect($0.frame) } ?? "nil",
              NSStringFromRect(window.frame))

        ObservationRelay.track { [weak self] in
            self?.render()
        }
        installKeyMonitor()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    deinit {
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
    }

    // MARK: - Content

    private func buildContent() {
        let root = NSView()
        root.wantsLayer = true
        content.view = root

        showInMainButton = ToolButton(theme: theme, symbol: "sidebar.left",
                                      tooltip: "Show in Main Window") { [weak self] in
            self?.showInMainWindow()
        }
        settingsButton = ToolButton(theme: theme, symbol: "textformat.size", tooltip: "Reading settings") { [weak self] in
            guard let self else { return }
            ReaderToolbarActions.presentReadingSettings(theme: theme, presenter: content)
        }
        chaptersButton = ToolButton(theme: theme, symbol: "list.bullet", tooltip: "Chapters") { [weak self] in
            self?.toggleChaptersPopover()
        }
        refreshButton = ToolButton(theme: theme, symbol: "arrow.clockwise",
                                   tooltip: "Refresh chapter from AO3") { [weak self] in
            self?.reader.refreshChaptersFromAO3()
        }
        commentsButton = ToolButton(theme: theme, symbol: "bubble.right", tooltip: "Chapter comments") { [weak self] in
            guard let self, let work else { return }
            ReaderToolbarActions.presentChapterComments(theme: theme, appState: appState, work: work,
                                                        chapterIndex: session.chapter, presenter: content)
        }
        bookmarkButton = ToolButton(theme: theme, symbol: "bookmark", tooltip: "Bookmark") { [weak self] in
            guard let self, let id = session.workID else { return }
            appState.toggleBookmark(id)
        }
        toolbar.configure(title: "", sub: nil)
        toolbar.setLeading([showInMainButton])
        toolbar.setTrailing([settingsButton, chaptersButton, refreshButton, commentsButton, bookmarkButton])

        content.addChild(reader)
        let readerView = reader.view
        toolbar.translatesAutoresizingMaskIntoConstraints = false
        readerView.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(toolbar)
        root.addSubview(readerView)
        NSLayoutConstraint.activate([
            toolbar.topAnchor.constraint(equalTo: root.topAnchor),
            toolbar.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            toolbar.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            readerView.topAnchor.constraint(equalTo: toolbar.bottomAnchor),
            readerView.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            readerView.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            readerView.bottomAnchor.constraint(equalTo: root.bottomAnchor),
        ])
    }

    /// ← / → change chapters; Escape leaves native full screen. Only for
    /// events in this window, never while typing or under a sheet.
    private func installKeyMonitor() {
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, let window, event.window === window,
                  window.attachedSheet == nil else { return event }
            if let editor = window.firstResponder as? NSTextView, editor.isEditable {
                return event
            }
            let hasModifiers = !event.modifierFlags.intersection([.command, .option, .control]).isEmpty
            guard !hasModifiers else { return event }
            switch event.keyCode {
            case 123: // ←
                reader.goToAdjacentChapter(-1)
                return nil
            case 124: // →
                reader.goToAdjacentChapter(1)
                return nil
            case 53: // Escape
                if content.presentedViewControllers?.isEmpty == false { return event }
                if let popover = chaptersPopover, popover.isShown { return event }
                if window.styleMask.contains(.fullScreen) {
                    window.toggleFullScreen(nil)
                    return nil
                }
                return event
            default:
                return event
            }
        }
    }

    // MARK: - Render

    private func render() {
        _ = theme.uiFontScale
        var overlayOpID: UInt64?
        defer {
            requestProgressOverlay.update(opID: overlayOpID, over: reader.view, in: content.view,
                                          theme: theme, appState: appState)
        }
        content.view.layer?.backgroundColor = theme.nsBg.cgColor
        toolbar.applyTheme()
        guard let id = session.workID, let work = appState.work(byID: id) else {
            renderedKey = nil
            return
        }
        let chapter = session.chapter
        overlayOpID = session.chapterFetchOp.opID

        window?.title = work.title
        let total = work.complete ? String(work.totalChapters) : "?"
        window?.subtitle = "Chapter \(chapter + 1) of \(total)"

        let bookmarked = appState.bookmarkedWorkIDs.contains(id)
        bookmarkButton.setSymbol(bookmarked ? "bookmark.fill" : "bookmark")
        bookmarkButton.tintOverride = bookmarked ? theme.nsAccent : nil

        if renderedKey?.0 != id || renderedKey?.1 != chapter {
            renderedKey = (id, chapter)
            reader.show(work: work, chapterIndex: chapter)
        }
    }

    // MARK: - Registry-facing

    func open(_ id: String, chapter: Int, at pos: Int?) {
        session.open(id, chapter: chapter, at: pos)
        render()
    }

    /// Re-point at a remembered place without `open`'s side effects
    /// (history, progress) — restoring after unlock.
    func restore(_ id: String, chapter: Int, at pos: Int?) {
        session.restore(id, chapter: chapter, at: pos)
        render()
    }

    /// This window as it stands, for restoring after unlock; nil when it
    /// has no work yet. `frame` is the un-full-screen frame so a restored
    /// window that leaves full screen lands where it was before.
    func snapshot(isKey: Bool) -> WorkWindowRegistry.Snapshot? {
        guard let id = session.workID, let window else { return nil }
        let isFullScreen = window.styleMask.contains(.fullScreen)
        return WorkWindowRegistry.Snapshot(
            workID: id,
            chapter: reader.chapterIndex,
            pos: reader.anchorOffset ?? session.resumePos,
            frame: isFullScreen ? (frameBeforeFullScreen ?? window.frame) : window.frame,
            isMiniaturized: window.isMiniaturized,
            isFullScreen: isFullScreen,
            wasKey: isKey)
    }

    /// Put back the window state `snapshot` recorded beyond frame and
    /// content: minimized, or in full screen. Called after `restore`.
    func applyRestoredState(_ snapshot: WorkWindowRegistry.Snapshot) {
        guard let window else { return }
        if snapshot.isFullScreen {
            frameBeforeFullScreen = snapshot.frame
            window.toggleFullScreen(nil)
        } else if snapshot.isMiniaturized {
            window.miniaturize(nil)
        }
    }

    /// The frame to return to when full screen ends — AppKit restores it
    /// itself, but only the window knows it while full screen is up, and
    /// the lock snapshot needs it to come back to the same place.
    private var frameBeforeFullScreen: NSRect?

    func bringToFront() {
        guard let window else { return }
        if window.isMiniaturized { window.deminiaturize(nil) }
        showWindow(nil)
        window.makeKeyAndOrderFront(nil)
    }

    func flushPendingPersist() {
        session.flushPendingPersist()
    }

    // MARK: - Actions

    private func toggleChaptersPopover() {
        if let popover = chaptersPopover, popover.isShown {
            popover.close()
            chaptersPopover = nil
            return
        }
        guard let id = session.workID else { return }
        chaptersPopover = ReaderToolbarActions.chaptersPopover(
            theme: theme, appState: appState, session: session,
            workID: id, anchor: chaptersButton) { [weak self] in
                self?.chaptersPopover?.close()
                self?.chaptersPopover = nil
            }
    }

    /// Hand the work back to the reading pane at this window's place —
    /// a move: the window closes (unregistering), then the pane opens.
    private func showInMainWindow() {
        guard let id = session.workID else { return }
        reader.flushPendingPersist()
        let chapter = reader.chapterIndex
        let pos = reader.anchorOffset ?? 0
        close()
        model.selectWork(id)
        model.openReaderInPane(id, chapter: chapter, at: pos)
        Self.mainWindow?.makeKeyAndOrderFront(nil)
    }

    private static var mainWindow: NSWindow? {
        NSApp.windows.first { $0.windowController is MainWindowController }
    }

    // MARK: - NSWindowDelegate

    func windowWillEnterFullScreen(_ notification: Notification) {
        if frameBeforeFullScreen == nil { frameBeforeFullScreen = window?.frame }
    }

    func windowDidExitFullScreen(_ notification: Notification) {
        frameBeforeFullScreen = nil
    }

    func windowWillClose(_ notification: Notification) {
        // The last debounced position lands before the reader goes away;
        // an in-flight chapter fetch is this window's alone to abort.
        reader.flushPendingPersist()
        reader.chapterTask.cancel()
        if let opID = session.chapterFetchOp.opID {
            appState.bridge.cancelOperation(opID)
        }
        if let keyMonitor {
            NSEvent.removeMonitor(keyMonitor)
            self.keyMonitor = nil
        }
        session.close()
        // The registry holds the only strong reference; drop it after the
        // close finishes rather than deallocating mid-close.
        let keepAlive = self
        registry.unregister(self)
        DispatchQueue.main.async { _ = keepAlive }
    }
}

// MARK: - ReaderSessionHost

extension WorkWindowController: ReaderSessionHost {
    func readerSessionDidClose(_ session: ReaderSession) {
        close()
    }

    /// End of the work: re-point this same window at the next work in the
    /// series — unless that work is already open elsewhere, in which case
    /// surface it there and leave this window on the finished work.
    func readerSession(_ session: ReaderSession, openNextWork id: String) {
        Task { @MainActor in
            if appState.work(byID: id) == nil {
                await appState.fetchWorkMetadata(id)
            }
            // Restricted/deleted next work: stay where we are.
            guard appState.work(byID: id) != nil, let current = session.workID else { return }
            if registry.show(id) { return }
            if model.readerOpen, model.selectedWorkID == id {
                Self.mainWindow?.makeKeyAndOrderFront(nil)
                return
            }
            reader.flushPendingPersist()
            registry.rekey(from: current, to: id)
            open(id, chapter: 0, at: nil)
        }
    }
}
