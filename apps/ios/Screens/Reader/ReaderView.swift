import SwiftUI

struct ReaderView: View {
    @Environment(AppTheme.self) var theme
    @Environment(AppState.self) var state
    @Environment(NavigationState.self) var nav
    @Environment(\.dismiss) var dismiss
    @Environment(\.horizontalSizeClass) var sizeClass
    @Environment(\.openWindow) var openWindow

    let workID: String
    let initialChapterIndex: Int

    @State var chapterIndex: Int
    @State var entireWork: Bool
    @State var chromeVisible: Bool = true
    @State var didConfigure = false
    @State var scrollProgress: Double = 0
    @State var isLoading = false
    @State var loadError: String?
    @State var didCancel = false
    @State var chapterTask = NetworkTask()
    @State var visibleChapterIndex: Int = 0
    @Environment(TTSController.self) var tts
    /// Identifies this reader as the owner of speech it starts.
    @State var readerToken = UUID()
    @State var showVoicePicker = false

    // Text-anchored position: the column owns the anchor (character offset
    // of the first visible line) and persists it debounced; the reader
    // asks it to land somewhere through restore requests.
    @State var textHandle = ReaderTextHandle()
    @State var restoreRequest: ReaderRestoreRequest?
    @State var restoreCounter = 0
    /// Where the reader was before the last chapter change — UI memory
    /// only, never persisted. Backs the footer's "return to previous
    /// position" control; empty on a fresh open.
    @State var returnPoint: ReaderPosition?

    /// Chapter-embedded images fetched this work (src → image), the fetches
    /// in flight, and per-image failure messages for the placeholder.
    @State var loadedImages: [String: UIImage] = [:]
    @State var imageStatus: [String: String] = [:]
    @State var loadingImages: Set<String> = []

    init(workID: String, chapterIndex: Int, entireWork: Bool = false) {
        self.workID = workID
        self.initialChapterIndex = chapterIndex
        _chapterIndex = State(initialValue: chapterIndex)
        _entireWork = State(initialValue: entireWork)
        _visibleChapterIndex = State(initialValue: chapterIndex)
    }

    var work: Work? {
        state.work(byID: workID)
    }

    var fetchedChapters: [UChapter]? {
        state.chaptersForWork(workID)
    }

    var fetchedChapter: UChapter? {
        guard let chapters = fetchedChapters,
              chapterIndex < chapters.count else { return nil }
        return chapters[chapterIndex]
    }

    var contentBlocks: [ParsedContentBlock]? {
        guard let ch = fetchedChapter,
              !ch.contentJson.isEmpty,
              ch.contentJson != "[]" else { return nil }
        let blocks = ParsedContentBlock.fromJSON(ch.contentJson)
        return blocks.isEmpty ? nil : blocks
    }

    var hasFetched: Bool {
        fetchedChapters != nil
    }

    var isFirstChapter: Bool {
        chapterIndex == 0
    }

    var postedChapterCount: Int {
        max(1, fetchedChapters?.count ?? work?.chapterCount ?? 1)
    }

    var isLastChapter: Bool {
        chapterIndex >= postedChapterCount - 1
    }

    /// The chapter the reader is in: the one showing, or in entire-work
    /// mode the one at the top of the viewport.
    var currentChapter: Int {
        entireWork ? visibleChapterIndex : chapterIndex
    }

    // MARK: - Column inputs

    /// What the text column shows: the open chapter, or every chapter.
    /// nil while there is nothing renderable (loading, error).
    func textContent(_ work: Work) -> ReaderTextContent? {
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

    var textStyle: ReaderTextStyle {
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
            chromeBottom: chromeVisible ? (tts.isReading(workID: workID) ? 130 : 80) : 32)
    }

    var ttsHighlight: ReaderBlockRef? {
        guard tts.isReading(workID: workID), let chapter = tts.source?.chapter else { return nil }
        return tts.highlightedBlockIndex.map { ReaderBlockRef(chapter: chapter, block: $0) }
    }

    /// Ask the column to land on `position` (consumed once that chapter's
    /// content is rendered).
    func requestRestore(_ position: ReaderPosition) {
        restoreCounter += 1
        restoreRequest = ReaderRestoreRequest(id: restoreCounter, position: position)
    }

    /// Where the reader is right now.
    var currentPosition: ReaderPosition {
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
                        if tts.isReading(workID: workID) {
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
                // Rebuilt after an unlock while this work was being read
                // aloud: take the running speech back so leaving stops it.
                if tts.isReading(workID: workID) { tts.owner = readerToken }
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
                // Leaving the reader ends its speech; the app locking (which
                // tears the view down too) keeps it playing (M4).
                if tts.owner == readerToken, state.bridge.launchState != .locked {
                    tts.stop()
                }
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

}

#Preview {
    NavigationStack {
        ReaderView(workID: "baker", chapterIndex: 0)
    }
    .environment(AppTheme())
    .environment(AppState())
    .environment(NavigationState())
}
