import AppKit

/// Every open work window, keyed by work id. The single authority on the
/// one-reader-per-work rule: `open` is the only way a window is created,
/// `unregister` (from the window's close) the only way an entry leaves,
/// and next-in-series re-pointing goes through `rekey` so the map never
/// lags the window's actual work.
///
/// A work is open in at most one place — the pane reader or one window.
/// Opening a work that already has a window surfaces that window; the
/// pane's `openReader` asks here first and defers to an existing window.
@MainActor
final class WorkWindowRegistry {
    private let theme: AppTheme
    private let appState: AppState
    /// Set by the model right after construction; the two reference each
    /// other (windows hand work back to the pane, the pane defers to
    /// windows), so this side is weak.
    weak var model: MacAppModel?

    private var windows: [String: WorkWindowController] = [:]

    /// One work window as it stood when the library locked — everything
    /// needed to put it back: content (work, chapter, in-chapter position)
    /// and place (frame, minimized / full screen, whether it was key).
    struct Snapshot {
        let workID: String
        let chapter: Int
        let pos: Int
        let frame: NSRect
        let isMiniaturized: Bool
        let isFullScreen: Bool
        let wasKey: Bool
    }

    /// Windows to restore after the next unlock, front to back, with the
    /// main window's place in that order — nil until a lock takes the
    /// windows away, cleared once they are back.
    private var suspended: (windows: [Snapshot], mainWindowIndex: Int)?

    init(theme: AppTheme, appState: AppState) {
        self.theme = theme
        self.appState = appState
    }

    var isEmpty: Bool { windows.isEmpty }

    /// The work window nearest the front, for cascading a new one off it.
    private var frontmostWindow: NSWindow? {
        NSApp.orderedWindows.first { $0.windowController is WorkWindowController }
    }

    func isOpen(_ id: String) -> Bool {
        windows[id] != nil
    }

    func window(for id: String) -> WorkWindowController? {
        windows[id]
    }

    /// Bring the window showing `id` forward. Returns false when there is
    /// none — the caller then opens the work wherever it meant to.
    @discardableResult
    func show(_ id: String) -> Bool {
        guard let controller = windows[id] else { return false }
        controller.bringToFront()
        return true
    }

    /// Show `id` in its own window at `chapter` / `pos`, or bring the
    /// window that already has it forward (its current place wins — the
    /// arguments are ignored). Fetches metadata first for a work the
    /// library doesn't know yet.
    func open(_ id: String, chapter: Int, at pos: Int?) {
        if show(id) { return }
        guard let model else { return }
        if appState.work(byID: id) != nil {
            create(id, chapter: chapter, at: pos, model: model)
            return
        }
        Task { @MainActor in
            await appState.fetchWorkMetadata(id)
            guard appState.work(byID: id) != nil, !isOpen(id) else { return }
            create(id, chapter: chapter, at: pos, model: model)
        }
    }

    @discardableResult
    private func create(_ id: String, chapter: Int, at pos: Int?, model: MacAppModel,
                        placement: WorkWindowController.Placement? = nil,
                        restoring: Bool = false) -> WorkWindowController {
        // The pane never keeps a reader on a work that has a window: land
        // its last position first, then close it — a move, not a copy.
        if model.readerOpen, model.selectedWorkID == id {
            model.paneReader.flushPendingPersist()
            model.closeReader()
        }
        let controller = WorkWindowController(theme: theme, appState: appState,
                                              model: model, registry: self,
                                              placement: placement ?? .cascade(from: frontmostWindow))
        windows[id] = controller
        if restoring {
            controller.restore(id, chapter: chapter, at: pos)
        } else {
            controller.open(id, chapter: chapter, at: pos)
        }
        controller.bringToFront()
        return controller
    }

    /// A window moved on to another work (next in series).
    func rekey(from old: String, to new: String) {
        guard let controller = windows.removeValue(forKey: old) else { return }
        windows[new] = controller
    }

    /// The window is closing — drop it from the map. Called from the
    /// window's own close path, the only way an entry leaves.
    func unregister(_ controller: WorkWindowController) {
        windows = windows.filter { $0.value !== controller }
    }

    /// Land every window's debounced position persist now — before a
    /// lock or quit takes the bridge away.
    func flushAll() {
        for controller in windows.values {
            controller.flushPendingPersist()
        }
    }

    func closeAll() {
        for controller in Array(windows.values) {
            controller.close()
        }
    }

    // MARK: - Lock / unlock

    /// The library is locking: remember every work window — content and
    /// place, in z-order — then close them all. Locking tears down the
    /// core, and a window left open would render against a dead bridge.
    /// Positions were flushed before the lock (see AppDelegate.lockIfIdle),
    /// so the reader's own anchor is the exact place to come back to.
    func suspendForLock() {
        guard !windows.isEmpty else { return }
        let keyWindow = NSApp.keyWindow
        var snapshots: [Snapshot] = []
        var mainWindowIndex = 0
        var sawMain = false
        for window in NSApp.orderedWindows {
            if window.windowController is MainWindowController {
                mainWindowIndex = snapshots.count
                sawMain = true
                continue
            }
            guard let controller = window.windowController as? WorkWindowController,
                  windows.values.contains(where: { $0 === controller }),
                  let snapshot = controller.snapshot(isKey: window === keyWindow) else { continue }
            snapshots.append(snapshot)
        }
        // Any window the ordered list missed (never shown, e.g. mid-fetch)
        // is not worth restoring; a hidden main window sits behind them all.
        if !sawMain { mainWindowIndex = snapshots.count }
        suspended = (snapshots, mainWindowIndex)
        closeAll()
    }

    /// The library unlocked: put back the windows `suspendForLock` took
    /// away — same works, chapters, positions, frames and stacking order,
    /// and the window that was key is key again. Nothing is recorded in
    /// history or progress: the reader is resuming, not opening.
    func restoreAfterUnlock() {
        guard let (snapshots, mainWindowIndex) = suspended else { return }
        suspended = nil
        guard let model, appState.bridge.isInitialized else { return }
        let mainWindow = NSApp.windows.first { $0.windowController is MainWindowController }
        var keyController: WorkWindowController?
        // Back to front: each orderFront lands above the previous one, so
        // the original stacking comes out of the replay order alone. The
        // main window had `mainWindowIndex` work windows in front of it —
        // it goes up right after the last window that was behind it.
        if mainWindowIndex == snapshots.count { mainWindow?.orderFront(nil) }
        for (index, snapshot) in snapshots.enumerated().reversed() {
            defer { if index == mainWindowIndex { mainWindow?.orderFront(nil) } }
            // Already open again (the pane took it, or an earlier restore
            // did): leave that alone rather than open the work twice.
            if isOpen(snapshot.workID) { continue }
            if model.readerOpen, model.selectedWorkID == snapshot.workID { continue }
            guard appState.work(byID: snapshot.workID) != nil else { continue }
            let controller = create(snapshot.workID, chapter: snapshot.chapter, at: snapshot.pos,
                                    model: model, placement: .frame(snapshot.frame), restoring: true)
            controller.applyRestoredState(snapshot)
            if snapshot.wasKey { keyController = controller }
        }
        if let keyController {
            keyController.bringToFront()
        } else {
            mainWindow?.makeKeyAndOrderFront(nil)
        }
    }
}
