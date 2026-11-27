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
            steps: watched ? bridge.contentQueueSteps() : [:])
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

    /// Pause or resume the download queue. A pause lets every work in
    /// flight finish in full (the monitor shows "Pausing" until they
    /// have), then nothing further starts.
    func setDownloadQueuePaused(_ paused: Bool) {
        bridge.setContentQueuePaused(paused)
        refreshDownloadQueue()
    }

    /// Queue a work for the background download: the whole work, or —
    /// with `chapters` — only the chapters numbered in that range. A
    /// work already queued keeps its one entry, widened to cover both. A
    /// chapter the library already holds is not fetched again.
    func queueDownload(workID: UInt64, chapters: ClosedRange<UInt32>? = nil) {
        bridge.queueWorkContent(workId: workID, firstChapter: chapters?.lowerBound, lastChapter: chapters?.upperBound)
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

    /// The requests of each work in flight, by source id.
    func contentQueueSteps() -> [String: [UContentQueueStep]] {
        app?.contentQueueSteps() ?? [:]
    }

    func queueWorkContent(workId: UInt64, firstChapter: UInt32?, lastChapter: UInt32?) {
        try? app?.queueWorkContent(workId: workId, firstChapter: firstChapter, lastChapter: lastChapter)
    }

    func setContentQueuePaused(_ paused: Bool) {
        app?.setContentQueuePaused(paused: paused)
    }
}
