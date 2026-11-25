import Foundation

// MARK: - Download queue: status, contents, pause

extension AppState {
    /// Mirror the core's download queue into `downloadQueue`: its status
    /// always, its contents only while a monitor is showing.
    func refreshDownloadQueue() {
        guard let status = bridge.contentQueueStatus() else { return }
        let watched = downloadQueue.isWatched
        downloadQueue.update(
            status: status,
            items: watched ? bridge.contentQueueItems() : nil,
            steps: watched ? bridge.contentQueueSteps() : [])
    }

    /// The core reported a queue change. A listing page queues its works
    /// one after another, so a burst of these is folded into one refresh.
    func downloadQueueChanged() {
        guard !downloadQueueRefreshPending else { return }
        downloadQueueRefreshPending = true
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 200_000_000)
            downloadQueueRefreshPending = false
            refreshDownloadQueue()
        }
    }

    /// Pause or resume the download queue. A pause lets the work in
    /// flight finish in full (the monitor shows "Pausing" until it has),
    /// then nothing further starts.
    func setDownloadQueuePaused(_ paused: Bool) {
        bridge.setContentQueuePaused(paused)
        refreshDownloadQueue()
    }

    /// A monitor UI appeared or went away.
    func watchDownloadQueue(_ watching: Bool) {
        downloadQueue.isWatched = watching
        if watching { refreshDownloadQueue() }
    }
}

extension RustBridge {
    func contentQueueStatus() -> UContentQueueStatus? {
        app?.contentQueueStatus()
    }

    func contentQueueItems() -> [UContentQueueItem] {
        (try? app?.contentQueueItems()) ?? []
    }

    func contentQueueSteps() -> [UContentQueueStep] {
        app?.contentQueueSteps() ?? []
    }

    func setContentQueuePaused(_ paused: Bool) {
        app?.setContentQueuePaused(paused: paused)
    }
}
