import SwiftUI

extension ReaderView {
    // MARK: - Loading

    /// Cache-first, then Tor. `force` bypasses the session and database
    /// caches — the fetch rewrites the cached rows, so chapters whose text
    /// changed (or arrived) since the original fetch show their current
    /// content.
    func loadChapter(force: Bool = false) async {
        guard let workId = UInt64(workID), !isLoading else { return }

        if !force {
            // A cached copy only satisfies the request if it reaches the
            // chapter being opened — a work updated since the last fetch
            // falls through to the network for the new chapter.
            let cached = state.bridge.getCachedChapters(workId)
            if !cached.isEmpty, chapterIndex < cached.count {
                state.fetchedChapters[workID] = cached
                if state.fetchedWorks[workID] == nil, let w = state.bridge.getCachedWork(workId) {
                    state.fetchedWorks[workID] = AppState.workFromSummary(w)
                }
                return
            }
        }

        isLoading = true
        loadError = nil
        didCancel = false
        chapterTask.reset()
        do {
            // Request-tracking standard: the minted id rides on every request
            // of this fetch, retries included, so the banner and per-op
            // cancel address exactly this reader's operation.
            let chapters = try await state.chapterFetchOp.run(state.bridge) { opID in
                try await state.retryOnTimeout(task: chapterTask, using: state.bridge) {
                    try await self.state.bridge.fetchChapters(workId, opID: opID)
                }
            }
            state.fetchedChapters[workID] = chapters
            if state.fetchedWorks[workID] == nil, let w = state.bridge.getCachedWork(workId) {
                state.fetchedWorks[workID] = AppState.workFromSummary(w)
            }
            // Stale metadata promised a chapter AO3 doesn't have — land on
            // the last real one rather than an empty page.
            if !chapters.isEmpty, chapterIndex >= chapters.count {
                chapterIndex = chapters.count - 1
                visibleChapterIndex = chapterIndex
                requestRestore(ReaderPosition(chapter: chapterIndex, offset: 0))
                state.setProgress(workID, chapter: chapterIndex + 1, pos: 0)
            }
        } catch {
            if !chapterTask.isCancelled && !error.isCancellation {
                loadError = error.localizedDescription
            }
        }
        isLoading = false
    }

    /// Refetch the work's chapters from AO3, bypassing the caches.
    func refreshChaptersFromAO3() {
        guard UInt64(workID) != nil, !isLoading else { return }
        textHandle.controller?.flushPendingPersist()
        let position = currentPosition
        state.fetchedChapters[workID] = nil
        loadError = nil
        requestRestore(position)
        Task { await loadChapter(force: true) }
    }

    /// Abort this reader's chapter fetch — only this one; other fetches,
    /// subscription checks and searches keep running.
    func cancelLoad() {
        didCancel = true
        chapterTask.cancel()
        if let opID = state.chapterFetchOp.opID {
            state.bridge.cancelOperation(opID)
        }
        isLoading = false
    }

    // MARK: - Images

    static func imageSrcs(in blocks: [ParsedContentBlock]) -> [String] {
        var srcs: [String] = []
        func walk(_ blocks: [ParsedContentBlock]) {
            for block in blocks {
                switch block {
                case .image(let src, _):
                    if !srcs.contains(src) { srcs.append(src) }
                case .blockquote(let inner):
                    walk(inner)
                case .list(_, let items):
                    items.forEach(walk)
                default:
                    break
                }
            }
        }
        walk(blocks)
        return srcs
    }

    /// With auto-load on: adopt already-cached images synchronously and
    /// fetch the rest. With it off, every image stays a tap-to-load
    /// placeholder — cached or not.
    func primeAndLoadImages(in blocks: [ParsedContentBlock]) {
        for src in Self.imageSrcs(in: blocks) where loadedImages[src] == nil {
            guard theme.imageAutoLoad else { continue }
            if let data = state.bridge.cachedChapterImage(url: src),
               let image = UIImage(data: data) {
                loadedImages[src] = image
            } else {
                loadImage(src)
            }
        }
    }

    func loadImage(_ src: String) {
        guard !loadingImages.contains(src), loadedImages[src] == nil else { return }
        loadingImages.insert(src)
        imageStatus[src] = "Loading image…"
        Task { @MainActor in
            do {
                let data = try await state.bridge.fetchChapterImage(url: src, maxBytes: theme.imageMaxBytes)
                if let image = UIImage(data: data) {
                    loadedImages[src] = image
                    imageStatus[src] = nil
                } else {
                    let head = data.prefix(16).map { String(format: "%02x", $0) }.joined(separator: " ")
                    state.bridge.writeLog(level: "ERROR", tag: "image",
                        message: "UIImage decode failed for \(src): \(data.count) bytes, head [\(head)]")
                    imageStatus[src] = "Couldn’t decode image — tap to retry"
                }
            } catch {
                state.bridge.writeLog(level: "ERROR", tag: "image",
                    message: "Fetch failed for \(src): \(error.localizedDescription)")
                imageStatus[src] = "\(error.localizedDescription) — tap to retry"
            }
            loadingImages.remove(src)
        }
    }

    // MARK: - Chapter navigation & position

    /// The saved offset for a chapter: the stored progress when it is for
    /// this chapter, else the top.
    func savedPosition(for chapter: Int) -> Int {
        guard let p = state.progressMap[workID], p.chapter == chapter + 1 else { return 0 }
        return max(0, p.pos)
    }

    /// Point the reader at another chapter. Remembers where the reader was
    /// so the footer's return control can take them back; an explicit
    /// `pos` (the return control) wins over the saved progress.
    func goToChapter(_ index: Int, at pos: Int? = nil) {
        let clamped = max(0, min(index, postedChapterCount - 1))
        guard clamped != currentChapter || pos != nil else { return }
        textHandle.controller?.flushPendingPersist()
        stashReturnPoint()
        let target = pos ?? savedPosition(for: clamped)
        chapterIndex = clamped
        visibleChapterIndex = clamped
        requestRestore(ReaderPosition(chapter: clamped, offset: target))
        chromeVisible = true
        state.markWorkRead(workID)
        state.setProgress(workID, chapter: clamped + 1, pos: target)
    }

    func stashReturnPoint() {
        returnPoint = currentPosition
    }

    /// The footer's ↩: swap back to the chapter left behind. `goToChapter`
    /// stashes the chapter being left, so the control swaps between the two
    /// positions rather than consuming itself.
    func returnToPreviousPosition() {
        guard let point = returnPoint else { return }
        goToChapter(point.chapter, at: point.offset)
    }

    /// The library was replaced: drop the debounced persist (it describes
    /// the old library) and land wherever the new one says this work is.
    /// A work the new library isn't reading stays put; the next scroll
    /// re-enrolls it.
    func reanchorFromStorage() {
        textHandle.controller?.cancelPendingPersist()
        guard let progress = state.progressMap[workID] else { return }
        let chapter = max(0, min(progress.chapter - 1, postedChapterCount - 1))
        returnPoint = nil
        chapterIndex = chapter
        visibleChapterIndex = chapter
        requestRestore(ReaderPosition(chapter: chapter, offset: max(0, progress.pos)))
        aoyoPosLog("reanchor work=\(workID) -> ch\(progress.chapter)@\(progress.pos)")
    }

    /// Move this reader into its own window — the window picks up
    /// exactly where this one was (chapter + anchored line) and this
    /// reader closes: a move, not a copy, so the work has one reader.
    func moveToWindow() {
        textHandle.controller?.flushPendingPersist()
        let position = currentPosition
        state.setProgress(workID, chapter: position.chapter + 1, pos: position.offset)
        openWindow(value: WorkWindowValue(workID: workID,
                                          chapterIndex: position.chapter,
                                          entireWork: entireWork))
        dismiss()
    }
}
