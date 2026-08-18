import AppKit

// MARK: - Chapter acquisition (cache-first, then Tor)

extension ReaderViewController {
    func loadChapters(force: Bool = false) async {
        guard let work else { return }

        // Mock/preview works carry their content inline.
        if UInt64(work.id) == nil {
            if let content = work.content {
                chapters = content.enumerated().map { index, chapter in
                    UChapter(chapterId: Int64(index), number: UInt32(index + 1), title: chapter.title,
                             contentJson: "", notesBefore: "", notesAfter: "")
                }
            }
            renderChapter()
            return
        }
        guard let workId = UInt64(work.id) else { return }

        // A cached copy only satisfies the request if it reaches the chapter
        // being opened — a work updated since the last fetch falls through
        // to the network for the new chapter.
        if !force {
            // Already fetched this session?
            if let fetched = appState.chaptersForWork(work.id), !fetched.isEmpty,
               chapterIndex < fetched.count {
                chapters = fetched
                renderChapter()
                return
            }

            // Local database cache (downloaded / recently read works).
            let cached = appState.bridge.getCachedChapters(workId)
            if !cached.isEmpty, chapterIndex < cached.count {
                appState.fetchedChapters[work.id] = cached
                chapters = cached
                renderChapter()
                return
            }
        }

        // Fetch over the network (Tor-gated inside retryOnTimeout).
        isLoading = true
        loadError = nil
        renderChapter()
        do {
            let fetched = try await appState.retryOnTimeout(task: chapterTask, using: appState.bridge) {
                try await self.appState.bridge.fetchChapters(workId)
            }
            appState.fetchedChapters[work.id] = fetched
            chapters = fetched
            // Stale metadata promised a chapter AO3 doesn't have — land on
            // the last real one rather than an empty page.
            if !fetched.isEmpty, chapterIndex >= fetched.count {
                chapterIndex = fetched.count - 1
                model.readerChapter = chapterIndex
            }
        } catch {
            if !chapterTask.isCancelled && !error.isCancellation {
                loadError = error.localizedDescription
            }
        }
        isLoading = false
        renderChapter()
    }

    func retryLoad() {
        loadError = nil
        Task { await loadChapters() }
    }

    /// Toolbar refresh: refetch the work's chapters from AO3, bypassing the
    /// session and database caches — the fetch rewrites the cached rows, so
    /// chapters whose text changed (or arrived) since the original fetch
    /// show their current content.
    func refreshChaptersFromAO3() {
        guard let work, UInt64(work.id) != nil, !isLoading else { return }
        appState.fetchedChapters[work.id] = nil
        chapters = nil
        loadError = nil
        Task { await loadChapters(force: true) }
    }

    func cancelLoad() {
        chapterTask.cancel()
        appState.bridge.cancelRequest()
        model.closeReader()
    }

    // MARK: - Chapter navigation & progress

    @objc func nextChapter() {
        goChapter(1)
    }

    @objc func openNextWorkInSeries() {
        guard let next = work?.nextInSeries?.nextWorkID else { return }
        model.openNextWorkInSeries(next)
    }

    /// Keyboard navigation entry point (← / → in the reading pane).
    func goToAdjacentChapter(_ delta: Int) {
        goChapter(delta)
    }

    func goChapter(_ delta: Int) {
        guard let work else { return }
        let target = chapterIndex + delta
        guard target >= 0, target < postedChapterCount else { return }
        // Remember the position being left so the footer's return control
        // can take the reader back (in-memory only).
        model.stashReturnPoint(chapter: chapterIndex, pos: anchorOffset ?? 0)
        chapterIndex = target
        chapterPct = 0
        anchorOffset = nil
        expectedTopLine = nil
        verifyGeneration += 1
        model.readerChapter = target
        appState.pushHistory(work.id)
        appState.markWorkRead(work.id)
        // Reaching a chapter records it even if the reader never scrolls.
        appState.setProgress(work.id, chapter: target + 1, pos: 0)
        scrollToTop()
        // Stepping into a chapter the cached copy doesn't have yet (the
        // work updated since the last fetch): refetch past the caches —
        // the loading overlay renders until the new chapter arrives.
        if let chapters, target >= chapters.count {
            refreshChaptersFromAO3()
            return
        }
        renderChapter()
    }

    func scrollToTop() {
        scrollView.contentView.scroll(to: .zero)
        scrollView.reflectScrolledClipView(scrollView.contentView)
    }

    func refreshProgress(persist: Bool) {
        guard let documentHeight = scrollView.documentView?.bounds.height else { return }
        let visible = scrollView.contentView.bounds
        let max = documentHeight - visible.height
        chapterPct = max > 0 ? min(1, Swift.max(0, visible.origin.y / max)) : 0
        updateProgress()
        // Persist only when the geometry is trustworthy: a pending or
        // in-flight restore means the viewport is mid-churn and a captured
        // offset could be layout noise, not the reader's place.
        if persist, let work, currentChapterContent != nil,
           pendingRestorePos == nil, !restorePending, !suppressTracking {
            // 1-based chapter; the position is the settled text anchor (nil
            // while the header above the body shows — that IS the chapter
            // top). The rendered document's length rides along so the
            // position reads back as a chapter fraction.
            let pos = anchorOffset ?? 0
            appState.setProgress(work.id, chapter: chapterIndex + 1, pos: pos,
                                 chapterLen: textView.textStorage?.length ?? 0)
            if abs(chapterPct - lastPersistLogPct) > 0.05 {
                lastPersistLogPct = chapterPct
                posLog("persist work=\(work.id) ch=\(chapterIndex + 1) pos=\(pos) stored=\(appState.progressMap[work.id].map { "ch\($0.chapter)@\($0.pos)" } ?? "nil")")
            }
        }
    }

    func updateProgress() {
        guard let work else { return }
        let total = Double(Swift.max(1, work.complete ? work.totalChapters : postedChapterCount))
        let bookPct = (Double(chapterIndex) + chapterPct) / total
        footer.update(chapterPct: chapterPct, bookPct: bookPct,
                      canGoBack: chapterIndex > 0,
                      canGoForward: chapterIndex < postedChapterCount - 1,
                      returnChapter: model.readerReturnPoint.map { $0.chapter + 1 })
    }

    // MARK: - Chapter-embedded images

    private static func imageSrcs(in blocks: [ParsedContentBlock]) -> [String] {
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

    /// Synchronously adopt already-cached images (downloaded works, earlier
    /// taps this session), and start fetches for the rest when auto-load is
    /// on. Tap-to-load is the default: uncached images stay placeholders.
    func primeAndLoadImages(in blocks: [ParsedContentBlock]) {
        for src in Self.imageSrcs(in: blocks) where loadedChapterImages[src] == nil {
            if let data = appState.bridge.cachedChapterImage(url: src),
               let image = NSImage(data: data) {
                loadedChapterImages[src] = image
            } else if theme.imageAutoLoad {
                loadChapterImage(src)
            }
        }
    }

    private func loadChapterImage(_ src: String) {
        guard !loadingChapterImages.contains(src), loadedChapterImages[src] == nil else { return }
        loadingChapterImages.insert(src)
        chapterImageStatus[src] = "Loading image…"
        renderChapter()
        Task { @MainActor in
            do {
                let data = try await appState.bridge.fetchChapterImage(url: src, maxBytes: theme.imageMaxBytes)
                if let image = NSImage(data: data) {
                    loadedChapterImages[src] = image
                    chapterImageStatus[src] = nil
                    appState.bridge.writeLog(level: "INFO", tag: "image",
                        message: "Decoded \(data.count) bytes into \(Int(image.size.width))×\(Int(image.size.height)) for \(src)")
                } else {
                    let head = data.prefix(16).map { String(format: "%02x", $0) }.joined(separator: " ")
                    appState.bridge.writeLog(level: "ERROR", tag: "image",
                        message: "NSImage decode failed for \(src): \(data.count) bytes, head [\(head)]")
                    chapterImageStatus[src] = "Couldn’t decode image — tap to retry"
                }
            } catch {
                appState.bridge.writeLog(level: "ERROR", tag: "image",
                    message: "Fetch failed for \(src): \(error.localizedDescription)")
                chapterImageStatus[src] = "\(error.localizedDescription) — tap to retry"
            }
            loadingChapterImages.remove(src)
            renderChapter()
        }
    }
}

// MARK: - Link handling (tap-to-load images)

extension ReaderViewController: NSTextViewDelegate {
    func textView(_ textView: NSTextView, clickedOnLink link: Any, at charIndex: Int) -> Bool {
        if let src = ContentBlockRenderer.imageSrc(from: link) {
            chapterImageStatus[src] = nil  // clear a stale error before retrying
            loadChapterImage(src)
            return true
        }
        guard let url = ExternalLinkOpener.url(from: link) else { return false }
        ExternalLinkOpener.open(url, bridge: appState.bridge)
        return true
    }
}
