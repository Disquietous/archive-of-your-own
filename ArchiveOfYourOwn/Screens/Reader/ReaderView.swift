import SwiftUI

struct ReaderView: View {
    @Environment(AppTheme.self) private var theme
    @Environment(AppState.self) private var state
    @Environment(NavigationState.self) private var nav
    @Environment(\.dismiss) private var dismiss

    let workID: String
    let initialChapterIndex: Int

    @State private var chapterIndex: Int
    @State private var entireWork: Bool
    @State private var chromeVisible: Bool = true
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

    private var chapter: ChapterContent {
        guard let work else {
            return ChapterContent(title: "Chapter", paragraphs: [])
        }
        return MockData.buildChapter(for: work, index: chapterIndex)
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

    private var isLastChapter: Bool {
        guard let work else { return true }
        return chapterIndex >= work.chapterCount - 1
    }

    private var isLastWrittenChapter: Bool {
        guard let work else { return true }
        return chapterIndex >= work.chapterCount - 1
    }

    var body: some View {
        if let work {
            ZStack(alignment: .top) {
                if entireWork {
                    entireWorkContent(work)
                } else {
                    readerContent(work)
                }

                if chromeVisible {
                    topChrome(work)
                        .transition(.move(edge: .top).combined(with: .opacity))
                }

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
            .navigationBarBackButtonHidden(true)
            .toolbar(.hidden, for: .tabBar)
            .toolbar(.hidden, for: .navigationBar)
            .onAppear {
                state.pushHistory(workID)
            }
            .task(id: workID) {
                if fetchedChapters == nil, UInt64(workID) != nil {
                    await loadChapter()
                }
            }
        }
    }

    // MARK: - Privacy Dot

    private var privacyDot: some View {
        VStack {
            HStack {
                Spacer()
                Circle()
                    .fill(theme.sage)
                    .frame(width: 8, height: 8)
                    .shadow(color: theme.sage.opacity(0.4), radius: 3, x: 0, y: 0)
                    .padding(.trailing, 16)
                    .padding(.top, 12)
            }
            Spacer()
        }
        .zIndex(10)
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
                            LazyVStack(alignment: .leading, spacing: 0) {
                                Spacer()
                                    .frame(height: chromeVisible ? 80 : 50)

                                ForEach(Array(chapters.enumerated()), id: \.offset) { index, ch in
                                    entireWorkChapterSection(work: work, chapter: ch, index: index, isLast: index == chapters.count - 1)
                                        .id("chapter-\(index)")
                                        .onAppear {
                                            if !suppressVisibleTracking {
                                                visibleChapterIndex = index
                                            }
                                        }
                                }

                                entireWorkEnd(work)

                                Spacer()
                                    .frame(height: chromeVisible ? 80 : 50)
                            }
                            .padding(.horizontal, theme.readMargin)
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
                .onTapGesture {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        chromeVisible.toggle()
                    }
                }
                .onAppear {
                    if initialChapterIndex > 0 {
                        suppressVisibleTracking = true
                        visibleChapterIndex = initialChapterIndex
                        proxy.scrollTo("chapter-\(initialChapterIndex)", anchor: .top)
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                            suppressVisibleTracking = false
                        }
                    }
                }
                .onChange(of: fetchedChapters?.count) {
                    if initialChapterIndex > 0 {
                        suppressVisibleTracking = true
                        visibleChapterIndex = initialChapterIndex
                        proxy.scrollTo("chapter-\(initialChapterIndex)", anchor: .top)
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                            suppressVisibleTracking = false
                        }
                    }
                }
                .onChange(of: scrollTarget) { _, target in
                    if let target {
                        suppressVisibleTracking = true
                        visibleChapterIndex = target
                        withAnimation {
                            proxy.scrollTo("chapter-\(target)", anchor: .top)
                        }
                        scrollTarget = nil
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                            suppressVisibleTracking = false
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func entireWorkChapterSection(work: Work, chapter: UChapter, index: Int, isLast: Bool) -> some View {
        VStack(alignment: .leading, spacing: theme.readingLineSpacing) {
            if index > 0 {
                chapterDivider
            }

            Text("\(work.fandom) · Ch \(index + 1) of \(work.totalChapters)")
                .font(Typography.uiCaption())
                .foregroundStyle(theme.ink3)
                .textCase(.uppercase)
                .tracking(0.3)
                .padding(.bottom, 4)

            Text(chapter.title.isEmpty ? "Chapter \(index + 1)" : chapter.title)
                .font(Typography.readerChTitle())
                .foregroundStyle(theme.ink)
                .padding(.bottom, 8)

            let blocks = ParsedContentBlock.fromJSON(chapter.contentJson)
            if !blocks.isEmpty {
                ContentBlockView(blocks: blocks, highlightedIndex: tts.highlightedBlockIndex)
            }
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
        }
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

                        Text("\(work.fandom) · Ch \(chapterIndex + 1) of \(work.totalChapters)")
                            .font(Typography.uiCaption())
                            .foregroundStyle(theme.ink3)
                            .textCase(.uppercase)
                            .tracking(0.3)
                            .padding(.bottom, 4)

                        Text(fetchedChapter?.title.isEmpty == false ? fetchedChapter!.title : chapter.title)
                            .font(Typography.readerChTitle())
                            .foregroundStyle(theme.ink)
                            .padding(.bottom, 8)

                        if let blocks = contentBlocks {
                            ContentBlockView(blocks: blocks, highlightedIndex: tts.highlightedBlockIndex)
                        } else if isLoading {
                            NetworkLoadingView(message: "Loading chapter…", task: chapterTask, operation: "chapters") {
                                didCancel = true
                                chapterTask.cancel()
                                state.bridge.cancelRequest()
                                isLoading = false
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
                                Task { await loadChapter() }
                            })
                        }

                        chapterEnd

                        Spacer()
                            .frame(height: chromeVisible ? 80 : 50)
                    }
                    .padding(.horizontal, theme.readMargin)
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
            .onTapGesture {
                withAnimation(.easeInOut(duration: 0.2)) {
                    chromeVisible.toggle()
                }
            }
            .onChange(of: contentBlocks) {
                proxy.scrollTo("chapterTop", anchor: .top)
                chromeVisible = true
            }
            } // ScrollViewReader
        }
    }

    // MARK: - Shared Loading/Error Views

    private var loadingContent: some View {
        VStack(alignment: .leading, spacing: theme.readingLineSpacing) {
            Spacer().frame(height: chromeVisible ? 80 : 50)
            NetworkLoadingView(message: "Loading work…", task: chapterTask, operation: "chapters") {
                didCancel = true
                chapterTask.cancel()
                state.bridge.cancelRequest()
                isLoading = false
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

    private func loadChapter() async {
        guard let workId = UInt64(workID) else { return }

        let cached = state.bridge.getCachedChapters(workId)
        if !cached.isEmpty {
            state.fetchedChapters[workID] = cached
            if state.fetchedWorks[workID] == nil, let w = state.bridge.getCachedWork(workId) {
                state.fetchedWorks[workID] = AppState.workFromSummary(w)
            }
            return
        }

        isLoading = true
        loadError = nil
        didCancel = false
        chapterTask.reset()
        do {
            let chapters = try await state.retryOnTimeout(task: chapterTask, using: state.bridge) {
                try await self.state.bridge.fetchChapters(workId)
            }
            state.fetchedChapters[workID] = chapters
            if state.fetchedWorks[workID] == nil, let w = state.bridge.getCachedWork(workId) {
                state.fetchedWorks[workID] = AppState.workFromSummary(w)
            }
        } catch {
            if !chapterTask.isCancelled && !"\(error)".contains("cancelled") {
                loadError = error.localizedDescription
            }
        }
        isLoading = false
    }

    // MARK: - Drop Cap

    private func dropCapParagraph(_ text: String) -> some View {
        let firstLetter = text.prefix(1)
        let rest = text.dropFirst()

        return HStack(alignment: .top, spacing: 4) {
            Text(String(firstLetter))
                .font(.custom(theme.readingFont.fontName, size: CGFloat(theme.fontSize) * 3.2))
                .foregroundStyle(theme.accent)
                .lineSpacing(0)
                .baselineOffset(-CGFloat(theme.fontSize) * 0.6)
                .frame(alignment: .topLeading)

            Text(String(rest))
                .font(theme.readingBodyFont)
                .foregroundStyle(theme.ink)
                .lineSpacing(theme.readingLineSpacing)
        }
        .padding(.bottom, theme.readingLineSpacing)
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

            if isLastWrittenChapter {
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
            } else {
                Button {
                    chapterIndex += 1
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
        HStack(spacing: 10) {
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

            Spacer()

            Button {
                nav.goHome()
            } label: {
                Image(systemName: "house")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(theme.ink2)
                    .frame(width: 36, height: 36)
            }
            .buttonStyle(IconButtonPressStyle())

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

    // MARK: - Chapter Selector Menu

    private func chapterMenu(_ work: Work, currentIndex: Int, onSelect: @escaping (Int) -> Void) -> some View {
        Menu {
            ForEach(0..<work.chapterCount, id: \.self) { i in
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
                Text("Ch. \(currentIndex + 1)/\(work.chapterCount)")
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

    // MARK: - Bottom Chrome (single chapter)

    private func entireWorkToggle(_ work: Work) -> some View {
        Group {
            if work.chapterCount > 1 {
                Button {
                    if entireWork {
                        chapterIndex = visibleChapterIndex
                        entireWork = false
                    } else {
                        suppressVisibleTracking = true
                        visibleChapterIndex = chapterIndex
                        scrollTarget = chapterIndex
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
                    if !isFirstChapter {
                        chapterIndex -= 1
                    }
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

                chapterMenu(work, currentIndex: chapterIndex) { selected in
                    chapterIndex = selected
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
                    if !isLastChapter {
                        chapterIndex += 1
                    }
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

    // MARK: - Scroll Handling

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

        state.setProgress(workID, chapter: chapterIndex + 1, pct: progress)
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

        state.setProgress(workID, chapter: visibleChapterIndex + 1, pct: progress)
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
