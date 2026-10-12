import SwiftUI

/// Chapter list for the reader toolbar — jump anywhere in the work.
struct ChapterListPopover: View {
    @Bindable var theme: AppTheme
    @Bindable var appState: AppState
    @Bindable var session: ReaderSession
    let workID: String
    let onSelect: () -> Void

    var body: some View {
        let chapters = appState.chaptersForWork(workID) ?? []
        ScrollViewReader { proxy in
            ScrollView {
                VStack(spacing: 0) {
                    ForEach(Array(chapters.enumerated()), id: \.offset) { index, chapter in
                        chapterRow(index: index, chapter: chapter)
                            .id(index)
                    }
                    if chapters.isEmpty {
                        Text("Chapters are still loading…")
                            .font(Font(MacFont.ui(12.5)))
                            .foregroundStyle(theme.ink3)
                            .padding(16)
                    }
                }
                .padding(.vertical, 6)
            }
            .onAppear { proxy.scrollTo(session.chapter, anchor: .center) }
        }
        .frame(width: 300, height: 360)
        .background(theme.surface)
    }

    private func chapterRow(index: Int, chapter: UChapter) -> some View {
        let current = index == session.chapter
        let title = chapter.title.isEmpty ? "Chapter \(index + 1)" : chapter.title
        return Button {
            session.open(workID, chapter: index)
            onSelect()
        } label: {
            HStack(spacing: 10) {
                Text("\(index + 1)")
                    .font(Font(MacFont.ui(11, weight: .bold)))
                    .foregroundStyle(current ? theme.onAccent : theme.ink3)
                    .frame(minWidth: 22, minHeight: 22)
                    .background(current ? theme.accent : theme.surface2)
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                Text(title)
                    .font(Font(MacFont.ui(12.5, weight: current ? .semibold : .regular)))
                    .foregroundStyle(current ? theme.ink : theme.ink2)
                    .lineLimit(1)
                Spacer()
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
