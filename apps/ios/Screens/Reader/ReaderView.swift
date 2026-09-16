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

    /// Where the reader was before the last chapter change — UI memory
    /// only, never persisted. Backs the footer's "return to previous
    /// position" control; empty on a fresh open.
    private struct ReturnPoint: Equatable {
        /// 0-based chapter index.
        let chapter: Int
        /// Block index within that chapter.
        let pos: Int
    }

    @State private var chapterIndex: Int
    @State private var entireWork: Bool
    @State private var chromeVisible: Bool = true
    @State private var didConfigure = false
    @State private var scrollProgress: Double = 0
    @State private var lastScrollOffset: CGFloat = 0
    @State private var isLoading = false
    @State private var loadError: String?
    @State private var didCancel = false
    @State private var chapterTask = NetworkTask()
    @State private var visibleChapterIndex: Int = 0
    @State private var scrollTarget: Int?
    @State private var suppressVisibleTracking = false
    @State private var tts = TTSController()
    @State private var showVoicePicker = false

    // Block-index anchoring (D2): the topmost visible block is the reading
    // position; it persists debounced and restores on the next open.
    @State private var anchorBlock: Int = 0
    @State private var pendingRestore: ReaderBlockID?
    @State private var returnPoint: ReturnPoint?
    @State private var persistTask: Task<Void, Never>?

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

    /// iPad / wide layouts honor the measure setting as a maximum column
    /// width; a phone's width is the measure.
    private var columnMaxWidth: CGFloat {
        sizeClass == .regular ? CGFloat(theme.measure) : .infinity
    }

    var body: some View {
        if let work {
            ZStack(alignment: .top) {
                if entireWork {
                    entireWorkContent(work)
                } else {
                    readerContent(work)
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
                pendingRestore = ReaderBlockID(chapter: chapterIndex, block: pos)
                state.setProgress(workID, chapter: chapterIndex + 1, pos: pos)
            }
            .onDisappear {
                flushPendingPersist()
                nav.readerImmersive = false
            }
            .task(id: workID) {
                if fetchedChapters == nil, UInt64(workID) != nil {
                    await loadChapter()
                }
            }
        }
    }

    // MARK: - Entire Work Content

    private func entireWorkContent(_ work: Work) -> some View {
        GeometryReader { outerGeo in
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        Color.clear
                            .frame(height: 0)
                            .id("chapterTop")

                        if let chapters = fetchedChapters, !chapters.isEmpty {
                            // Chapter headers and their blocks are direct
                            // children of the lazy stack so every block is a
                            // scroll target (visibility tracking by block).
                            LazyVStack(alignment: .leading, spacing: 0) {
                                Spacer()
                                    .frame(height: chromeVisible ? 80 : 50)

                                ForEach(Array(chapters.enumerated()), id: \.offset) { index, ch in
                                    entireWorkChapterHeader(work: work, chapter: ch, index: index)
                                        .id("chapter-\(index)")
                                        .onAppear {
                                            if !suppressVisibleTracking {
                                                visibleChapterIndex = index
                                            }
                                        }
                                    let blocks = ParsedContentBlock.fromJSON(ch.contentJson)
                                    if !blocks.isEmpty {
                                        ContentBlockView(blocks: blocks,
                                                         highlightedIndex: tts.highlightedBlockIndex,
                                                         anchorChapter: index)
                                    }
                                }

                                entireWorkEnd(work)

                                Spacer()
                                    .frame(height: chromeVisible ? 80 : 50)
                            }
                            .scrollTargetLayout()
                            .padding(.horizontal, theme.readMargin)
                            .frame(maxWidth: columnMaxWidth)
                            .frame(maxWidth: .infinity)
                        } else if isLoading {
                            loadingContent
                                .padding(.horizontal, theme.readMargin)
                        } else if let error = loadError {
                            errorContent(error)
                                .padding(.horizontal, theme.readMargin)
                        } else if didCancel {
                            cancelledContent
                                .padding(.horizontal, theme.readMargin)
                        } else if !hasFetched {
                            loadingContent
                                .padding(.horizontal, theme.readMargin)
                        } else {
                            errorContent("Chapter content could not be loaded.")
                                .padding(.horizontal, theme.readMargin)
                        }
                    }
                    .background(
                        GeometryReader { contentGeo in
                            Color.clear
                                .preference(
                                    key: ScrollOffsetKey.self,
                                    value: contentGeo.frame(in: .named("entireWorkScroll")).minY
                                )
                        }
                    )
                }
                .coordinateSpace(name: "entireWorkScroll")
                .onPreferenceChange(ScrollOffsetKey.self) { offset in
                    handleEntireWorkScroll(offset: offset, viewHeight: outerGeo.size.height)
                }
                .onScrollTargetVisibilityChange(idType: ReaderBlockID.self, threshold: 0.0) { visible in
                    handleVisibleBlocks(visible)
                }
                .onTapGesture {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        chromeVisible.toggle()
                    }
                }
                .onAppear {
                    restoreEntireWork(proxy)
                }
                .onChange(of: fetchedChapters?.count) {
                    restoreEntireWork(proxy)
                }
                .onChange(of: pendingRestore) {
                    restoreEntireWork(proxy)
                }
                .onChange(of: scrollTarget) { _, target in
                    if let target {
                        flushPendingPersist()
                        stashReturnPoint()
                        // The return control records the block to land on;
                        // a plain chapter jump lands on the chapter top.
                        let block = pendingRestore?.chapter == target ? (pendingRestore?.block ?? 0) : 0
                        pendingRestore = nil
                        suppressVisibleTracking = true
                        visibleChapterIndex = target
                        anchorBlock = block
                        withAnimation {
                            if block > 0 {
                                proxy.scrollTo(ReaderBlockID(chapter: target, block: block), anchor: .top)
                            } else {
                                proxy.scrollTo("chapter-\(target)", anchor: .top)
                            }
                        }
                        scrollTarget = nil
                        state.setProgress(workID, chapter: target + 1, pos: block)
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                            suppressVisibleTracking = false
                        }
                    }
                }
            }
        }
    }

    /// Land on the opened chapter's saved block (or its top) once the
    /// chapters are in.
    private func restoreEntireWork(_ proxy: ScrollViewProxy) {
        guard let restore = pendingRestore, fetchedChapters?.isEmpty == false else { return }
        pendingRestore = nil
        guard restore.chapter > 0 || restore.block > 0 else { return }
        suppressVisibleTracking = true
        visibleChapterIndex = restore.chapter
        anchorBlock = restore.block
        DispatchQueue.main.async {
            if restore.block > 0 {
                proxy.scrollTo(restore, anchor: .top)
            } else {
                proxy.scrollTo("chapter-\(restore.chapter)", anchor: .top)
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                suppressVisibleTracking = false
            }
        }
    }

    @ViewBuilder
    private func entireWorkChapterHeader(work: Work, chapter: UChapter, index: Int) -> some View {
        VStack(alignment: .leading, spacing: theme.readingLineSpacing) {
            if index > 0 {
                chapterDivider
            }

            Text("Ch \(index + 1) of \(work.totalChapters)")
                .font(Typography.uiCaption())
                .foregroundStyle(theme.ink3)
                .textCase(.uppercase)
                .tracking(0.3)
                .padding(.bottom, 4)

            Text(chapter.title.isEmpty ? "Chapter \(index + 1)" : chapter.title)
                .font(Typography.readerChTitle())
                .foregroundStyle(theme.ink)
                .padding(.bottom, 8)
        }
    }

    private var chapterDivider: some View {
        VStack(spacing: 24) {
            Text("· · ·")
                .font(Typography.detailTitle())
                .foregroundStyle(theme.ink3)
                .frame(maxWidth: .infinity)
                .padding(.top, 32)
                .padding(.bottom, 8)
        }
    }

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

    // MARK: - Reader Content (single chapter)

    private func readerContent(_ work: Work) -> some View {
        GeometryReader { outerGeo in
            ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    Color.clear
                        .frame(height: 0)
                        .id("chapterTop")

                    VStack(alignment: .leading, spacing: theme.readingLineSpacing) {
                        Spacer()
                            .frame(height: chromeVisible ? 80 : 50)

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

                        if let blocks = contentBlocks {
                            ContentBlockView(blocks: blocks, highlightedIndex: tts.highlightedBlockIndex,
                                             anchorChapter: chapterIndex)
                        } else if isLoading {
                            NetworkLoadingView(message: "Loading chapter…", task: chapterTask) {
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

                        chapterEnd

                        Spacer()
                            .frame(height: chromeVisible ? 80 : 50)
                    }
                    .scrollTargetLayout()
                    .padding(.horizontal, theme.readMargin)
                    .frame(maxWidth: columnMaxWidth)
                    .frame(maxWidth: .infinity)
                    .background(
                        GeometryReader { contentGeo in
                            Color.clear
                                .preference(
                                    key: ScrollOffsetKey.self,
                                    value: contentGeo.frame(in: .named("readerScroll")).minY
                                )
                        }
                    )
                }
            }
            .coordinateSpace(name: "readerScroll")
            .onPreferenceChange(ScrollOffsetKey.self) { offset in
                handleScroll(offset: offset, viewHeight: outerGeo.size.height)
            }
            .onScrollTargetVisibilityChange(idType: ReaderBlockID.self, threshold: 0.0) { visible in
                handleVisibleBlocks(visible)
            }
            .onTapGesture {
                withAnimation(.easeInOut(duration: 0.2)) {
                    chromeVisible.toggle()
                }
            }
            .onAppear {
                restoreSingleChapter(proxy)
            }
            .onChange(of: contentBlocks) {
                restoreSingleChapter(proxy)
            }
            .onChange(of: pendingRestore) {
                restoreSingleChapter(proxy)
            }
            } // ScrollViewReader
        }
    }

    /// Consume the pending restore once the chapter's blocks are rendered:
    /// land on the anchored block, or the chapter top when there is none.
    private func restoreSingleChapter(_ proxy: ScrollViewProxy) {
        guard let blocks = contentBlocks, let restore = pendingRestore,
              restore.chapter == chapterIndex else { return }
        pendingRestore = nil
        suppressVisibleTracking = true
        // A saved position past the end (the chapter shrank, or a stale
        // character-offset value) is a chapter top.
        let block = restore.block < blocks.count ? restore.block : 0
        anchorBlock = block
        DispatchQueue.main.async {
            if block > 0 {
                proxy.scrollTo(ReaderBlockID(chapter: restore.chapter, block: block), anchor: .top)
            } else {
                proxy.scrollTo("chapterTop", anchor: .top)
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                suppressVisibleTracking = false
            }
        }
    }

    // MARK: - Shared Loading/Error Views

    private var loadingContent: some View {
        VStack(alignment: .leading, spacing: theme.readingLineSpacing) {
            Spacer().frame(height: chromeVisible ? 80 : 50)
            NetworkLoadingView(message: "Loading work…", task: chapterTask) {
                cancelLoad()
            }
            Spacer().frame(height: chromeVisible ? 80 : 50)
        }
    }

    private func errorContent(_ message: String) -> some View {
        VStack(alignment: .leading, spacing: theme.readingLineSpacing) {
            Spacer().frame(height: chromeVisible ? 80 : 50)
            NetworkErrorView(message: message, onRetry: {
                Task { await loadChapter() }
            }, onGoBack: { dismiss() })
            Spacer().frame(height: chromeVisible ? 80 : 50)
        }
    }

    private var cancelledContent: some View {
        VStack(alignment: .leading, spacing: theme.readingLineSpacing) {
            Spacer().frame(height: chromeVisible ? 80 : 50)
            NetworkErrorView(message: "Loading was cancelled.", onRetry: {
                didCancel = false
                Task { await loadChapter() }
            }, onGoBack: { dismiss() })
            Spacer().frame(height: chromeVisible ? 80 : 50)
        }
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
                pendingRestore = ReaderBlockID(chapter: chapterIndex, block: 0)
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
        flushPendingPersist()
        state.fetchedChapters[workID] = nil
        loadError = nil
        pendingRestore = ReaderBlockID(chapter: chapterIndex, block: anchorBlock)
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

    // MARK: - Chapter navigation & position

    /// The saved block for a chapter: the stored progress when it is for
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
        guard clamped != chapterIndex else { return }
        flushPendingPersist()
        stashReturnPoint()
        let target = pos ?? savedPosition(for: clamped)
        chapterIndex = clamped
        anchorBlock = target
        pendingRestore = ReaderBlockID(chapter: clamped, block: target)
        chromeVisible = true
        state.markWorkRead(workID)
        state.setProgress(workID, chapter: clamped + 1, pos: target)
    }

    private func stashReturnPoint() {
        let chapter = entireWork ? visibleChapterIndex : chapterIndex
        returnPoint = ReturnPoint(chapter: chapter, pos: anchorBlock)
    }

    /// The footer's ↩: swap back to the chapter left behind. `goToChapter`
    /// stashes the chapter being left, so the control swaps between the two
    /// positions rather than consuming itself.
    private func returnToPreviousPosition() {
        guard let point = returnPoint else { return }
        if entireWork {
            // The chapter-jump path does the scroll and the stash; the
            // pending restore refines the landing to the recorded block.
            pendingRestore = ReaderBlockID(chapter: point.chapter, block: point.pos)
            scrollTarget = point.chapter
        } else {
            goToChapter(point.chapter, at: point.pos)
        }
    }

    /// The topmost visible block is the reading position.
    private func handleVisibleBlocks(_ visible: [ReaderBlockID]) {
        guard !suppressVisibleTracking, pendingRestore == nil,
              let top = visible.min(by: { ($0.chapter, $0.block) < ($1.chapter, $1.block) }) else { return }
        if entireWork {
            visibleChapterIndex = top.chapter
        } else if top.chapter != chapterIndex {
            return
        }
        anchorBlock = top.block
        schedulePersist()
    }

    /// Scroll ticks arrive continuously; the write waits until the reader
    /// has been still for a second.
    private func schedulePersist() {
        persistTask?.cancel()
        persistTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(1))
            guard !Task.isCancelled else { return }
            persistTask = nil
            persistProgressNow()
        }
    }

    private func persistProgressNow() {
        guard pendingRestore == nil, !suppressVisibleTracking, let chapters = fetchedChapters else { return }
        let chapter = entireWork ? visibleChapterIndex : chapterIndex
        guard chapter < chapters.count else { return }
        let count = ParsedContentBlock.fromJSON(chapters[chapter].contentJson).count
        state.setProgress(workID, chapter: chapter + 1, pos: anchorBlock, chapterLen: count)
    }

    /// Run any pending debounced persist immediately — before the reader is
    /// repointed or left so the last position isn't lost.
    private func flushPendingPersist() {
        guard persistTask != nil else { return }
        persistTask?.cancel()
        persistTask = nil
        persistProgressNow()
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
                } else if let blocks = contentBlocks {
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

    /// Move this reader into its own window — the window picks up
    /// exactly where this one was (chapter + anchored block) and this
    /// reader closes: a move, not a copy, so the work has one reader.
    private func moveToWindow() {
        flushPendingPersist()
        state.setProgress(workID, chapter: (entireWork ? visibleChapterIndex : chapterIndex) + 1, pos: anchorBlock)
        openWindow(value: WorkWindowValue(workID: workID,
                                          chapterIndex: entireWork ? visibleChapterIndex : chapterIndex,
                                          entireWork: entireWork))
        dismiss()
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
                    flushPendingPersist()
                    if entireWork {
                        chapterIndex = visibleChapterIndex
                        pendingRestore = ReaderBlockID(chapter: visibleChapterIndex, block: anchorBlock)
                        entireWork = false
                    } else {
                        suppressVisibleTracking = true
                        visibleChapterIndex = chapterIndex
                        pendingRestore = ReaderBlockID(chapter: chapterIndex, block: anchorBlock)
                        entireWork = true
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                            suppressVisibleTracking = false
                        }
                    }
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
                    scrollTarget = selected
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

    private func handleScroll(offset: CGFloat, viewHeight: CGFloat) {
        let delta = offset - lastScrollOffset
        if abs(delta) > 5 {
            let scrollingDown = delta < 0
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
        lastScrollOffset = offset

        let totalScroll = abs(offset)
        let progress = min(max(totalScroll / max(viewHeight, 1), 0), 1)
        scrollProgress = progress
    }

    private func handleEntireWorkScroll(offset: CGFloat, viewHeight: CGFloat) {
        let delta = offset - lastScrollOffset
        if abs(delta) > 5 {
            let scrollingDown = delta < 0
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
        lastScrollOffset = offset

        let totalScroll = abs(offset)
        let progress = min(max(totalScroll / max(viewHeight, 1), 0), 1)
        scrollProgress = progress
    }
}

// MARK: - Scroll Offset Preference Key

private struct ScrollOffsetKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
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
