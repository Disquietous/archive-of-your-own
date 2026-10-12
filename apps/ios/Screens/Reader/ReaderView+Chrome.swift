import SwiftUI

extension ReaderView {
    // MARK: - Chapter End (single chapter mode)

    @ViewBuilder
    var chapterEnd: some View {
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

    func topChrome(_ work: Work) -> some View {
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
                if tts.isReading(workID: workID) {
                    tts.stop()
                } else if let blocks = ttsBlocks {
                    tts.start(blocks, workID: workID, chapter: currentChapter, owner: readerToken)
                }
            } label: {
                Image(systemName: tts.isReading(workID: workID) ? "speaker.wave.2.fill" : "speaker.wave.2")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(tts.isReading(workID: workID) ? theme.accent : theme.ink2)
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
    var ttsBlocks: [ParsedContentBlock]? {
        guard let chapters = fetchedChapters, currentChapter < chapters.count else { return nil }
        let blocks = ParsedContentBlock.fromJSON(chapters[currentChapter].contentJson)
        return blocks.isEmpty ? nil : blocks
    }

    /// Reader actions that don't earn a chrome button of their own.
    var readerMenu: some View {
        let bookmarked = state.bookmarkedWorkIDs.contains(workID)
        return Menu {
            Button {
                refreshChaptersFromAO3()
            } label: {
                Label("Refresh Chapters from AO3", systemImage: "arrow.clockwise")
            }
            .disabled(UInt64(workID) == nil || isLoading)

            Button {
                presentFind()
            } label: {
                Label(entireWork ? "Find in Work" : "Find in Chapter", systemImage: "magnifyingglass")
            }
            .disabled(work.flatMap(textContent) == nil)

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

    func presentFind() {
        textHandle.controller?.presentFind()
    }

    /// Hardware keyboard: ←/→ change chapter, Esc shows the chrome (exits
    /// immersive) and, when it's already showing, leaves the reader — the
    /// mac reader's keys. Invisible buttons keep the shortcuts registered
    /// while the chrome is hidden.
    var keyboardShortcuts: some View {
        Group {
            Button { goToChapter(chapterIndex - 1) } label: { Text("") }
                .keyboardShortcut(.leftArrow, modifiers: [])
                .disabled(entireWork || isFirstChapter)
            Button { goToChapter(chapterIndex + 1) } label: { Text("") }
                .keyboardShortcut(.rightArrow, modifiers: [])
                .disabled(entireWork || isLastChapter)
            Button { presentFind() } label: { Text("") }
                .keyboardShortcut("f", modifiers: .command)
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
}
