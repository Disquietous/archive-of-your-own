import SwiftUI

struct ReaderView: View {
    @Environment(AppTheme.self) private var theme
    @Environment(AppState.self) private var state
    @Environment(NavigationState.self) private var nav
    @Environment(\.dismiss) private var dismiss
    @Environment(\.horizontalSizeClass) private var sizeClass
    @Environment(\.openWindow) private var openWindow

    let workID: String
    let initialChapterIndex: Int

    @State private var chapterIndex: Int
    @State private var entireWork: Bool
    @State private var chromeVisible: Bool = true
    @State private var didConfigure = false
    @State private var scrollProgress: Double = 0
    @State private var isLoading = false
    @State private var loadError: String?
    @State private var didCancel = false
    @State private var chapterTask = NetworkTask()
    @State private var visibleChapterIndex: Int = 0
    @State private var tts = TTSController()
    @State private var ttsChapter: Int = 0
    @State private var showVoicePicker = false

    // Text-anchored position: the column owns the anchor (character offset
    // of the first visible line) and persists it debounced; the reader
    // asks it to land somewhere through restore requests.
    @State private var textHandle = ReaderTextHandle()
    @State private var restoreRequest: ReaderRestoreRequest?
    @State private var restoreCounter = 0
    /// Where the reader was before the last chapter change — UI memory
    /// only, never persisted. Backs the footer's "return to previous
    /// position" control; empty on a fresh open.
    @State private var returnPoint: ReaderPosition?

    /// Chapter-embedded images fetched this work (src → image), the fetches
    /// in flight, and per-image failure messages for the placeholder.
    @State private var loadedImages: [String: UIImage] = [:]
    @State private var imageStatus: [String: String] = [:]
    @State private var loadingImages: Set<String> = []

    init(workID: String, chapterIndex: Int, entireWork: Bool = false) {
        self.workID = workID
        self.initialChapterIndex = chapterIndex
        _chapterIndex = State(initialValue: chapterIndex)
        _entireWork = State(initialValue: entireWork)
        _visibleChapterIndex = State(initialValue: chapterIndex)
    }

    private var work: Work? {
        state.work(byID: workID)
    }

    private var fetchedChapters: [UChapter]? {
        state.chaptersForWork(workID)
    }

    private var fetchedChapter: UChapter? {
        guard let chapters = fetchedChapters,
              chapterIndex < chapters.count else { return nil }
        return chapters[chapterIndex]
    }

    private var contentBlocks: [ParsedContentBlock]? {
        guard let ch = fetchedChapter,
              !ch.contentJson.isEmpty,
              ch.contentJson != "[]" else { return nil }
        let blocks = ParsedContentBlock.fromJSON(ch.contentJson)
        return blocks.isEmpty ? nil : blocks
    }

    private var hasFetched: Bool {
        fetchedChapters != nil
    }

    private var isFirstChapter: Bool {
        chapterIndex == 0
    }

    private var postedChapterCount: Int {
        max(1, fetchedChapters?.count ?? work?.chapterCount ?? 1)
    }

    private var isLastChapter: Bool {
        chapterIndex >= postedChapterCount - 1
    }

    /// The chapter the reader is in: the one showing, or in entire-work
    /// mode the one at the top of the viewport.
    private var currentChapter: Int {
        entireWork ? visibleChapterIndex : chapterIndex
    }

    // MARK: - Column inputs

    /// What the text column shows: the open chapter, or every chapter.
    /// nil while there is nothing renderable (loading, error).
    private func textContent(_ work: Work) -> ReaderTextContent? {
        guard let chapters = fetchedChapters, !chapters.isEmpty else { return nil }
        let total = work.totalChapters
        func section(_ index: Int) -> ReaderTextSection {
            let ch = chapters[index]
            return ReaderTextSection(
                chapterIndex: index,
                meta: "Ch \(index + 1) of \(total)",
                title: ch.title.isEmpty ? "Chapter \(index + 1)" : ch.title,
                blocks: ParsedContentBlock.fromJSON(ch.contentJson))
        }
        let sections: [ReaderTextSection]
        if entireWork {
            sections = chapters.indices.map(section)
        } else {
            guard contentBlocks != nil else { return nil }
            sections = [section(chapterIndex)]
        }
        // In entire-work mode the document holds every chapter; moving
        // between them must not rebuild it.
        let key = "\(workID)|\(entireWork)|\(entireWork ? -1 : chapterIndex)|"
            + chapters.map { "\($0.chapterId):\($0.contentJson.utf8.count)" }.joined(separator: ",")
        return ReaderTextContent(key: key, workID: workID, sections: sections)
    }

    private var textStyle: ReaderTextStyle {
        ReaderTextStyle(
            themeID: theme.activeTheme.id,
            fontName: theme.readingFont.fontName,
            fontSize: theme.fontSize,
            readLeading: theme.readLeading,
            hyphenation: theme.readHyphenation,
            justified: theme.readJustified,
            measure: sizeClass == .regular ? CGFloat(theme.measure) : nil,
            readMargin: theme.readMargin,
            chromeTop: chromeVisible ? 60 : 24,
            chromeBottom: chromeVisible ? (tts.isActive ? 130 : 80) : 32)
    }

    private var ttsHighlight: ReaderBlockRef? {
        tts.highlightedBlockIndex.map { ReaderBlockRef(chapter: ttsChapter, block: $0) }
    }

    /// Ask the column to land on `position` (consumed once that chapter's
    /// content is rendered).
    private func requestRestore(_ position: ReaderPosition) {
        restoreCounter += 1
        restoreRequest = ReaderRestoreRequest(id: restoreCounter, position: position)
    }

    /// Where the reader is right now.
    private var currentPosition: ReaderPosition {
        textHandle.controller?.currentPosition ?? ReaderPosition(chapter: currentChapter, offset: 0)
    }

    var body: some View {
        if let work {
            ZStack(alignment: .top) {
                if let content = textContent(work) {
                    ReaderTextView(
                        theme: theme,
                        content: content,
                        style: textStyle,
                        images: loadedImages,
                        imageStatus: imageStatus,
                        highlight: ttsHighlight,
                        restore: restoreRequest,
                        endView: AnyView(
                            Group {
                                if entireWork {
                                    entireWorkEnd(work)
                                } else {
                                    chapterEnd
                                }
                            }
                            .environment(theme)
                            .environment(state)
                            .environment(nav)
                        ),
                        handle: textHandle,
                        onPersist: { position, length in
                            state.setProgress(workID, chapter: position.chapter + 1,
                                              pos: position.offset, chapterLen: length)
                        },
                        onScroll: handleScroll,
                        onVisibleChapter: { visibleChapterIndex = $0 },
                        onTap: {
                            withAnimation(.easeInOut(duration: 0.2)) {
                                chromeVisible.toggle()
                            }
                        },
                        onImageTap: { src in
                            imageStatus[src] = nil  // clear a stale error before retrying
                            loadImage(src)
                        },
                        onLink: { url in
                            ExternalLinkOpener.open(url, bridge: state.bridge)
                        })
                    .ignoresSafeArea()
                } else {
                    statusContent(work)
                }

                VStack(spacing: 8) {
                    if chromeVisible {
                        topChrome(work)
                            .transition(.move(edge: .top).combined(with: .opacity))
                    }
                    if let opID = state.chapterFetchOp.opID {
                        RequestProgressBanner(opID: opID) {
                            cancelLoad()
                        }
                        .padding(.horizontal, theme.pad)
                        .transition(.move(edge: .top).combined(with: .opacity))
                    }
                }
                .animation(.easeInOut(duration: 0.2), value: state.chapterFetchOp.opID)

                if chromeVisible {
                    VStack {
                        Spacer()
                        if tts.isActive {
                            ttsControlBar
                        }
                        if entireWork {
                            entireWorkBottomChrome(work)
                        } else {
                            bottomChrome(work)
                        }
                    }
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
            .background(theme.bg)
            .background { keyboardShortcuts }
            .navigationBarBackButtonHidden(true)
            .toolbar(.hidden, for: .tabBar)
            .toolbar(.hidden, for: .navigationBar)
            // Immersive reading collapses the iPad split to this column;
            // showing the chrome brings the columns back (D1).
            .onChange(of: chromeVisible, initial: true) { _, visible in
                nav.readerImmersive = sizeClass == .regular && !visible
            }
            .onAppear {
                guard !didConfigure else { return }
                didConfigure = true
                // A fresh open lands in the user's preferred reading view.
                chromeVisible = !theme.fullscreenReading
                state.pushHistory(workID)
                state.markWorkRead(workID)
                // Opening a chapter enrolls the work in Currently Reading
                // immediately — scrolling only refines the position.
                let pos = savedPosition(for: chapterIndex)
                requestRestore(ReaderPosition(chapter: chapterIndex, offset: pos))
                state.setProgress(workID, chapter: chapterIndex + 1, pos: pos)
            }
            .onDisappear {
                textHandle.controller?.flushPendingPersist()
                nav.readerImmersive = false
            }
            .onChange(of: textContent(work)?.key, initial: true) {
                if let content = textContent(work) {
                    primeAndLoadImages(in: content.sections.flatMap(\.blocks))
                }
            }
            // The library file was replaced underneath the app (iCloud copy
            // adopted, backup restored): move to the position the new
            // library holds instead of persisting the old one over it.
            .onChange(of: state.libraryGeneration) {
                reanchorFromStorage()
            }
            .task(id: workID) {
                if fetchedChapters == nil, UInt64(workID) != nil {
                    await loadChapter()
                }
            }
        }
    }

    // MARK: - Loading / error states

    /// Shown in place of the column while there is nothing to render.
    private func statusContent(_ work: Work) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: theme.readingLineSpacing) {
                Spacer()
                    .frame(height: chromeVisible ? 80 : 50)

                if !entireWork {
                    Text("Ch \(chapterIndex + 1) of \(work.totalChapters)")
                        .font(Typography.uiCaption())
                        .foregroundStyle(theme.ink3)
                        .textCase(.uppercase)
                        .tracking(0.3)
                        .padding(.bottom, 4)

                    Text(fetchedChapter.map { $0.title.isEmpty ? "Chapter \(chapterIndex + 1)" : $0.title } ?? "Chapter \(chapterIndex + 1)")
                        .font(Typography.readerChTitle())
                        .foregroundStyle(theme.ink)
                        .padding(.bottom, 8)
                }

                if isLoading {
                    NetworkLoadingView(message: entireWork ? "Loading work…" : "Loading chapter…", task: chapterTask) {
                        cancelLoad()
                    }
                } else if let error = loadError {
                    NetworkErrorView(message: error, onRetry: {
                        Task { await loadChapter() }
                    }, onGoBack: { dismiss() })
                } else if didCancel {
                    NetworkErrorView(message: "Loading was cancelled.", onRetry: {
                        didCancel = false
                        Task { await loadChapter() }
                    }, onGoBack: { dismiss() })
                } else if !hasFetched {
                    NetworkLoadingView(message: "Loading chapter…") {
                        dismiss()
                    }
                } else {
                    NetworkErrorView(message: "Chapter content could not be loaded.", onRetry: {
                        Task { await loadChapter(force: true) }
                    })
                }

                Spacer()
                    .frame(height: chromeVisible ? 80 : 50)
            }
            .padding(.horizontal, theme.readMargin)
            .frame(maxWidth: sizeClass == .regular ? CGFloat(theme.measure) : .infinity)
            .frame(maxWidth: .infinity)
        }
        .onTapGesture {
            withAnimation(.easeInOut(duration: 0.2)) {
                chromeVisible.toggle()
            }
        }
    }

    // MARK: - Entire work end

    @ViewBuilder
    private func entireWorkEnd(_ work: Work) -> some View {
        VStack(spacing: 24) {
            Text("· · ·")
                .font(Typography.detailTitle())
                .foregroundStyle(theme.ink3)
                .frame(maxWidth: .infinity)
                .padding(.top, 24)

            // View comments
            Button {
                nav.presentedSheet = .viewComments(workID: workID, chapterID: nil)
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "text.bubble")
                        .font(.system(size: 14, weight: .semibold))
                    Text("View comments")
                        .font(Typography.smallButtonLabel())
                }
                .foregroundStyle(theme.ink)
                .frame(maxWidth: .infinity)
                .frame(height: 42)
                .background(
                    RoundedRectangle(cornerRadius: Radius.button)
                        .stroke(theme.line, lineWidth: 1)
                )
            }
            .buttonStyle(ButtonPressStyle())

            if work.complete {
                VStack(spacing: 6) {
                    Text("The end")
                        .font(Typography.sheetTitle())
                        .foregroundStyle(theme.ink)
                    Text("Thank you for reading.")
                        .font(Typography.uiBody())
                        .foregroundStyle(theme.ink3)
                }
            } else {
                VStack(spacing: 6) {
                    Text("You're all caught up")
                        .font(Typography.sheetTitle())
                        .foregroundStyle(theme.ink)
                    Text("New chapters will appear when they're posted.")
                        .font(Typography.uiBody())
                        .foregroundStyle(theme.ink3)
                }
            }

            if let next = work.nextInSeries?.nextWorkID {
                nextWorkInSeriesButton(next)
            }
        }
    }

    /// End-of-work jump to the next installment — lands on its detail page
    /// (which fetches metadata itself for never-opened works).
    private func nextWorkInSeriesButton(_ nextID: String) -> some View {
        Button {
            nav.openWork(nextID)
        } label: {
            Text("Next work in series")
                .font(Typography.buttonLabel())
                .foregroundStyle(theme.onAccent)
                .frame(maxWidth: .infinity)
                .frame(height: 48)
                .background(
                    RoundedRectangle(cornerRadius: Radius.button)
                        .fill(theme.accent)
                )
        }
        .buttonStyle(ButtonPressStyle())
    }

    // MARK: - Loading

    /// Cache-first, then Tor. `force` bypasses the session and database
    /// caches — the fetch rewrites the cached rows, so chapters whose text
    /// changed (or arrived) since the original fetch show their current
    /// content.
    private func loadChapter(force: Bool = false) async {
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
    private func refreshChaptersFromAO3() {
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
    private func cancelLoad() {
        didCancel = true
        chapterTask.cancel()
        if let opID = state.chapterFetchOp.opID {
            state.bridge.cancelOperation(opID)
        }
        isLoading = false
    }

    // MARK: - Images

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
    private func primeAndLoadImages(in blocks: [ParsedContentBlock]) {
        for src in Self.imageSrcs(in: blocks) where loadedImages[src] == nil {
            if let data = state.bridge.cachedChapterImage(url: src),
               let image = UIImage(data: data) {
                loadedImages[src] = image
            } else if theme.imageAutoLoad {
                loadImage(src)
            }
        }
    }

    private func loadImage(_ src: String) {
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
    private func savedPosition(for chapter: Int) -> Int {
        guard let p = state.progressMap[workID], p.chapter == chapter + 1 else { return 0 }
        return max(0, p.pos)
    }

    /// Point the reader at another chapter. Remembers where the reader was
    /// so the footer's return control can take them back; an explicit
    /// `pos` (the return control) wins over the saved progress.
    private func goToChapter(_ index: Int, at pos: Int? = nil) {
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

    private func stashReturnPoint() {
        returnPoint = currentPosition
    }

    /// The footer's ↩: swap back to the chapter left behind. `goToChapter`
    /// stashes the chapter being left, so the control swaps between the two
    /// positions rather than consuming itself.
    private func returnToPreviousPosition() {
        guard let point = returnPoint else { return }
        goToChapter(point.chapter, at: point.offset)
    }

    /// The library was replaced: drop the debounced persist (it describes
    /// the old library) and land wherever the new one says this work is.
    /// A work the new library isn't reading stays put; the next scroll
    /// re-enrolls it.
    private func reanchorFromStorage() {
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
    private func moveToWindow() {
        textHandle.controller?.flushPendingPersist()
        let position = currentPosition
        state.setProgress(workID, chapter: position.chapter + 1, pos: position.offset)
        openWindow(value: WorkWindowValue(workID: workID,
                                          chapterIndex: position.chapter,
                                          entireWork: entireWork))
        dismiss()
    }

    // MARK: - Chapter End (single chapter mode)

    @ViewBuilder
    private var chapterEnd: some View {
        VStack(spacing: 24) {
            Text("· · ·")
                .font(Typography.detailTitle())
                .foregroundStyle(theme.ink3)
                .frame(maxWidth: .infinity)
                .padding(.top, 24)

            if let ch = fetchedChapter, ch.chapterId > 0 {
                HStack(spacing: 12) {
                    Button {
                        nav.presentedSheet = .viewComments(workID: workID, chapterID: UInt64(ch.chapterId))
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: "text.bubble")
                                .font(.system(size: 13, weight: .semibold))
                            Text("Comments")
                                .font(Typography.smallButtonLabel())
                        }
                        .foregroundStyle(theme.ink)
                        .frame(maxWidth: .infinity)
                        .frame(height: 42)
                        .background(
                            RoundedRectangle(cornerRadius: Radius.button)
                                .stroke(theme.line, lineWidth: 1)
                        )
                    }
                    .buttonStyle(ButtonPressStyle())

                    Button {
                        nav.presentedSheet = .comment(workID: workID, chapterID: UInt64(ch.chapterId))
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: "bubble.right")
                                .font(.system(size: 13, weight: .semibold))
                            Text("Comment")
                                .font(Typography.smallButtonLabel())
                        }
                        .foregroundStyle(theme.ink)
                        .frame(maxWidth: .infinity)
                        .frame(height: 42)
                        .background(
                            RoundedRectangle(cornerRadius: Radius.button)
                                .stroke(theme.line, lineWidth: 1)
                        )
                    }
                    .buttonStyle(ButtonPressStyle())
                }
            }

            if isLastChapter {
                if work?.complete == true {
                    VStack(spacing: 6) {
                        Text("The end")
                            .font(Typography.sheetTitle())
                            .foregroundStyle(theme.ink)
                        Text("Thank you for reading.")
                            .font(Typography.uiBody())
                            .foregroundStyle(theme.ink3)
                    }
                } else {
                    VStack(spacing: 6) {
                        Text("You're all caught up")
                            .font(Typography.sheetTitle())
                            .foregroundStyle(theme.ink)
                        Text("New chapters will appear when they're posted.")
                            .font(Typography.uiBody())
                            .foregroundStyle(theme.ink3)
                    }
                }
                if let next = work?.nextInSeries?.nextWorkID {
                    nextWorkInSeriesButton(next)
                }
            } else {
                Button {
                    goToChapter(chapterIndex + 1)
                } label: {
                    Text("Next chapter")
                        .font(Typography.buttonLabel())
                        .foregroundStyle(theme.onAccent)
                        .frame(maxWidth: .infinity)
                        .frame(height: 48)
                        .background(
                            RoundedRectangle(cornerRadius: Radius.button)
                                .fill(theme.accent)
                        )
                }
                .buttonStyle(ButtonPressStyle())
            }
        }
    }

    // MARK: - Top Chrome

    private func topChrome(_ work: Work) -> some View {
        HStack(spacing: 8) {
            Button { dismiss() } label: {
                Image(systemName: "chevron.left")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(theme.ink)
                    .frame(width: 36, height: 36)
            }
            .buttonStyle(IconButtonPressStyle())

            Button {
                nav.openWork(workID)
            } label: {
                Text(work.title)
                    .font(Typography.uiBody())
                    .foregroundStyle(theme.accent)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }

            Spacer(minLength: 4)

            Button {
                if tts.isActive {
                    tts.stop()
                } else if let blocks = ttsBlocks {
                    ttsChapter = currentChapter
                    tts.setContent(blocks)
                    tts.play()
                }
            } label: {
                Image(systemName: tts.isActive ? "speaker.wave.2.fill" : "speaker.wave.2")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(tts.isActive ? theme.accent : theme.ink2)
                    .frame(width: 36, height: 36)
            }
            .buttonStyle(IconButtonPressStyle())

            Button {
                nav.presentedSheet = .readingSettings
            } label: {
                Text("Tt")
                    .font(.custom("HankenGrotesk", size: 17).weight(.bold))
                    .foregroundStyle(theme.ink2)
                    .frame(width: 36, height: 36)
            }
            .buttonStyle(IconButtonPressStyle())

            readerMenu

            PrivacyPillView {
                nav.presentedSheet = .privacy
            }
        }
        .padding(.horizontal, theme.pad)
        .padding(.top, 8)
        .padding(.bottom, 8)
        .background(
            theme.bg.opacity(0.95)
                .shadow(.drop(color: .black.opacity(0.05), radius: 4, y: 2))
        )
    }

    /// The blocks read aloud: the chapter the reader is in.
    private var ttsBlocks: [ParsedContentBlock]? {
        guard let chapters = fetchedChapters, currentChapter < chapters.count else { return nil }
        let blocks = ParsedContentBlock.fromJSON(chapters[currentChapter].contentJson)
        return blocks.isEmpty ? nil : blocks
    }

    /// Reader actions that don't earn a chrome button of their own.
    private var readerMenu: some View {
        let bookmarked = state.bookmarkedWorkIDs.contains(workID)
        return Menu {
            Button {
                refreshChaptersFromAO3()
            } label: {
                Label("Refresh Chapters from AO3", systemImage: "arrow.clockwise")
            }
            .disabled(UInt64(workID) == nil || isLoading)

            Button {
                state.toggleBookmark(workID)
            } label: {
                Label(bookmarked ? "Remove Bookmark" : "Bookmark",
                      systemImage: bookmarked ? "bookmark.slash" : "bookmark")
            }

            Button {
                if entireWork {
                    nav.presentedSheet = .viewComments(workID: workID, chapterID: nil)
                } else if let ch = fetchedChapter, ch.chapterId > 0 {
                    nav.presentedSheet = .viewComments(workID: workID, chapterID: UInt64(ch.chapterId))
                } else {
                    nav.presentedSheet = .viewComments(workID: workID, chapterID: nil)
                }
            } label: {
                Label("Comments", systemImage: "bubble.right")
            }

            if WorkWindowValue.isSupported, UInt64(workID) != nil, nav.usesDetailColumn {
                Button {
                    moveToWindow()
                } label: {
                    Label("Open in New Window", systemImage: "macwindow.badge.plus")
                }
            }

            Divider()

            Button {
                nav.openWork(workID)
            } label: {
                Label("Work Details", systemImage: "doc.text")
            }

            Button {
                nav.goHome()
            } label: {
                Label("Home", systemImage: "house")
            }
        } label: {
            Image(systemName: "ellipsis")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(theme.ink2)
                .frame(width: 36, height: 36)
        }
    }

    /// Hardware keyboard: ←/→ change chapter, Esc shows the chrome (exits
    /// immersive) and, when it's already showing, leaves the reader — the
    /// mac reader's keys. Invisible buttons keep the shortcuts registered
    /// while the chrome is hidden.
    private var keyboardShortcuts: some View {
        Group {
            Button { goToChapter(chapterIndex - 1) } label: { Text("") }
                .keyboardShortcut(.leftArrow, modifiers: [])
                .disabled(entireWork || isFirstChapter)
            Button { goToChapter(chapterIndex + 1) } label: { Text("") }
                .keyboardShortcut(.rightArrow, modifiers: [])
                .disabled(entireWork || isLastChapter)
            Button {
                if !chromeVisible {
                    withAnimation(.easeInOut(duration: 0.2)) { chromeVisible = true }
                } else {
                    dismiss()
                }
            } label: { Text("") }
                .keyboardShortcut(.escape, modifiers: [])
        }
        .frame(width: 0, height: 0)
        .opacity(0)
        .accessibilityHidden(true)
    }

    // MARK: - Chapter Selector Menu

    private func chapterMenu(_ work: Work, currentIndex: Int, onSelect: @escaping (Int) -> Void) -> some View {
        Menu {
            ForEach(0..<postedChapterCount, id: \.self) { i in
                let title: String = {
                    if let chs = fetchedChapters, i < chs.count, !chs[i].title.isEmpty {
                        return chs[i].title
                    }
                    return "Chapter \(i + 1)"
                }()
                Button {
                    onSelect(i)
                } label: {
                    HStack {
                        Text("Ch. \(i + 1): \(title)")
                        if i == currentIndex {
                            Image(systemName: "checkmark")
                        }
                    }
                }
            }
        } label: {
            HStack(spacing: 4) {
                Text("Ch. \(currentIndex + 1)/\(postedChapterCount)")
                    .font(.custom("HankenGrotesk", size: 13).weight(.semibold))
                    .foregroundStyle(theme.ink)
                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(theme.ink3)
            }
            .padding(.horizontal, 10)
            .frame(height: 32)
        }
    }

    /// "↩ Ch. N" — back to the chapter the reader came from.
    @ViewBuilder
    private var returnButton: some View {
        if let point = returnPoint {
            Button {
                returnToPreviousPosition()
            } label: {
                Text("↩ Ch. \(point.chapter + 1)")
                    .font(.custom("HankenGrotesk", size: 13).weight(.semibold))
                    .foregroundStyle(theme.accent)
                    .padding(.horizontal, 8)
                    .frame(height: 32)
            }
            .buttonStyle(IconButtonPressStyle())
            .accessibilityLabel("Return to chapter \(point.chapter + 1)")
        }
    }

    // MARK: - Bottom Chrome (single chapter)

    private func entireWorkToggle(_ work: Work) -> some View {
        Group {
            if postedChapterCount > 1 {
                Button {
                    // The column re-renders for the new mode and lands back
                    // on the same line.
                    textHandle.controller?.flushPendingPersist()
                    let position = currentPosition
                    entireWork.toggle()
                    chapterIndex = position.chapter
                    visibleChapterIndex = position.chapter
                    requestRestore(position)
                } label: {
                    Image(systemName: entireWork ? "book.pages" : "book.pages.fill")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(entireWork ? theme.accent : theme.ink2)
                        .frame(width: 36, height: 36)
                }
                .buttonStyle(IconButtonPressStyle())
            }
        }
    }

    private func bottomChrome(_ work: Work) -> some View {
        VStack(spacing: 0) {
            ProgressTrackView(progress: scrollProgress)

            HStack {
                Button {
                    goToChapter(chapterIndex - 1)
                } label: {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(isFirstChapter ? theme.ink3.opacity(0.4) : theme.ink2)
                        .frame(width: 36, height: 36)
                }
                .buttonStyle(IconButtonPressStyle())
                .disabled(isFirstChapter)

                entireWorkToggle(work)

                Spacer()

                returnButton

                chapterMenu(work, currentIndex: chapterIndex) { selected in
                    goToChapter(selected)
                }

                Spacer()

                Button {
                    if let ch = fetchedChapter, ch.chapterId > 0 {
                        nav.presentedSheet = .viewComments(workID: workID, chapterID: UInt64(ch.chapterId))
                    }
                } label: {
                    Image(systemName: "bubble.right")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(theme.ink2)
                        .frame(width: 36, height: 36)
                }
                .buttonStyle(IconButtonPressStyle())

                Button {
                    goToChapter(chapterIndex + 1)
                } label: {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(isLastChapter ? theme.ink3.opacity(0.4) : theme.ink2)
                        .frame(width: 36, height: 36)
                }
                .buttonStyle(IconButtonPressStyle())
                .disabled(isLastChapter)
            }
            .padding(.horizontal, theme.pad)
            .padding(.vertical, 8)
        }
        .background(
            theme.bg.opacity(0.95)
                .shadow(.drop(color: .black.opacity(0.05), radius: 4, y: -2))
        )
    }

    // MARK: - Bottom Chrome (entire work)

    private func entireWorkBottomChrome(_ work: Work) -> some View {
        VStack(spacing: 0) {
            ProgressTrackView(progress: scrollProgress)

            HStack {
                entireWorkToggle(work)

                Spacer()

                returnButton

                chapterMenu(work, currentIndex: visibleChapterIndex) { selected in
                    goToChapter(selected)
                }

                Spacer()

                Button {
                    nav.presentedSheet = .viewComments(workID: workID, chapterID: nil)
                } label: {
                    Image(systemName: "bubble.right")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(theme.ink2)
                        .frame(width: 36, height: 36)
                }
                .buttonStyle(IconButtonPressStyle())
            }
            .padding(.horizontal, theme.pad)
            .padding(.vertical, 8)
        }
        .background(
            theme.bg.opacity(0.95)
                .shadow(.drop(color: .black.opacity(0.05), radius: 4, y: -2))
        )
    }

    // MARK: - TTS Control Bar

    private var ttsControlBar: some View {
        VStack(spacing: 0) {
            HStack(spacing: 16) {
                Button { tts.skipBack() } label: {
                    Image(systemName: "backward.fill")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(theme.ink2)
                        .frame(width: 36, height: 36)
                }
                .buttonStyle(IconButtonPressStyle())

                Button {
                    if tts.isPlaying { tts.pause() } else { tts.play() }
                } label: {
                    Image(systemName: tts.isPlaying ? "pause.fill" : "play.fill")
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(theme.accent)
                        .frame(width: 44, height: 36)
                }
                .buttonStyle(IconButtonPressStyle())

                Button { tts.skipForward() } label: {
                    Image(systemName: "forward.fill")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(theme.ink2)
                        .frame(width: 36, height: 36)
                }
                .buttonStyle(IconButtonPressStyle())

                Spacer()

                Text("¶ \(tts.currentParagraphIndex + 1)/\(tts.totalParagraphs)")
                    .font(.custom("HankenGrotesk", size: 12).weight(.medium))
                    .foregroundStyle(theme.ink3)
                    .monospacedDigit()

                Button { tts.cycleRate() } label: {
                    Text(tts.rateLabel)
                        .font(.custom("HankenGrotesk", size: 13).weight(.bold))
                        .foregroundStyle(theme.ink)
                        .frame(width: 36, height: 28)
                }
                .buttonStyle(IconButtonPressStyle())

                Button { showVoicePicker = true } label: {
                    Image(systemName: "person.wave.2")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(theme.ink2)
                        .frame(width: 36, height: 36)
                }
                .buttonStyle(IconButtonPressStyle())

                Button { tts.stop() } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(theme.ink3)
                        .frame(width: 28, height: 28)
                }
                .buttonStyle(IconButtonPressStyle())
            }
            .padding(.horizontal, theme.pad)
            .padding(.vertical, 6)
        }
        .background(
            theme.bg.opacity(0.95)
                .shadow(.drop(color: .black.opacity(0.05), radius: 4, y: -2))
        )
        .sheet(isPresented: $showVoicePicker) {
            VoicePickerSheet(tts: tts)
                .environment(theme)
        }
    }

    // MARK: - Scroll Handling

    /// Reader movement from the column: hide the chrome scrolling down,
    /// show it scrolling up; keep the progress track current.
    private func handleScroll(delta: CGFloat, progress: Double) {
        if abs(delta) > 5 {
            let scrollingDown = delta > 0
            if scrollingDown && chromeVisible {
                withAnimation(.easeInOut(duration: 0.2)) {
                    chromeVisible = false
                }
            } else if !scrollingDown && !chromeVisible {
                withAnimation(.easeInOut(duration: 0.2)) {
                    chromeVisible = true
                }
            }
        }
        scrollProgress = progress
    }
}

#Preview {
    NavigationStack {
        ReaderView(workID: "baker", chapterIndex: 0)
    }
    .environment(AppTheme())
    .environment(AppState())
    .environment(NavigationState())
}
