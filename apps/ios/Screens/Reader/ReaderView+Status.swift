import SwiftUI

extension ReaderView {
    // MARK: - Loading / error states

    /// Shown in place of the column while there is nothing to render.
    func statusContent(_ work: Work) -> some View {
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
    func entireWorkEnd(_ work: Work) -> some View {
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
    func nextWorkInSeriesButton(_ nextID: String) -> some View {
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
}
