import SwiftUI

extension ReaderView {
    // MARK: - Chapter Selector Menu

    func chapterMenu(_ work: Work, currentIndex: Int, onSelect: @escaping (Int) -> Void) -> some View {
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
    var returnButton: some View {
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

    func entireWorkToggle(_ work: Work) -> some View {
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

    func bottomChrome(_ work: Work) -> some View {
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

    func entireWorkBottomChrome(_ work: Work) -> some View {
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

    var ttsControlBar: some View {
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
    func handleScroll(delta: CGFloat, progress: Double) {
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
