import SwiftUI

/// Work detail — the reading pane's master/detail "detail" state.
/// Centered ~720pt column per the handoff.
struct DetailView: View {
    @Bindable var theme: AppTheme
    @Bindable var model: MacAppModel
    let work: Work

    private var progress: Double { model.progress(for: work) }
    private var started: Bool { progress > 0 }
    private var currentChapter: Int { model.progressMap[work.id]?.chapter ?? 1 }
    private var warnOK: Bool { work.warnings.contains("No Archive") }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                Text(work.fandom)
                    .font(Font(MacFont.ui(13, weight: .bold)))
                    .foregroundStyle(theme.accent)
                    .padding(.bottom, 10)
                Text(work.title)
                    .font(Font(MacFont.serif(38, weight: .bold)))
                    .foregroundStyle(theme.ink)
                    .lineSpacing(2)
                    .padding(.bottom, 10)
                (Text("by ").foregroundStyle(theme.ink2)
                    + Text(work.author).foregroundStyle(theme.accent).fontWeight(.semibold))
                    .font(Font(MacFont.ui(16)))
                    .padding(.bottom, 4)
                Text(work.relationship)
                    .font(Font(MacFont.ui(14)))
                    .foregroundStyle(theme.ink3)
                    .padding(.bottom, 20)

                pills.padding(.bottom, 22)
                actions.padding(.bottom, 26)
                statGrid.padding(.bottom, 24)
                summaryBox.padding(.bottom, 22)
                tags.padding(.bottom, 26)
                chapters
            }
            .padding(.init(top: 34, leading: 48, bottom: 60, trailing: 48))
            .frame(maxWidth: 720)
            .frame(maxWidth: .infinity)
        }
    }

    private var pills: some View {
        FlowLayout(spacing: 8) {
            pill("\(work.rating.letter) · \(work.rating.rawValue)",
                 bg: theme.accent.opacity(0.14), fg: theme.accent)
            pill(warnOK ? "No warnings" : "Author chose not to warn",
                 icon: warnOK ? "checkmark.shield" : "eye",
                 bg: (warnOK ? theme.sage : theme.accent2).opacity(0.15),
                 fg: warnOK ? theme.sage : theme.accent2)
            pill(work.complete ? "Complete" : "Work in progress", bg: theme.surface2, fg: theme.ink2)
            pill("Updated \(work.updated)", bg: theme.surface2, fg: theme.ink3)
        }
    }

    private func pill(_ label: String, icon: String? = nil, bg: Color, fg: Color) -> some View {
        HStack(spacing: 6) {
            if let icon {
                Image(systemName: icon).font(.system(size: 11, weight: .medium))
            }
            Text(label)
        }
        .font(Font(MacFont.ui(12.5, weight: .semibold)))
        .foregroundStyle(fg)
        .padding(.horizontal, 11)
        .padding(.vertical, 5)
        .background(bg)
        .clipShape(Capsule())
    }

    private var actions: some View {
        HStack(spacing: 10) {
            Button {
                model.openReader(work.id, chapter: started ? currentChapter - 1 : 0)
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "book")
                        .font(.system(size: 15, weight: .semibold))
                    Text(started ? "Continue · Ch. \(currentChapter)" : "Start reading")
                        .font(Font(MacFont.ui(14.5, weight: .bold)))
                }
                .foregroundStyle(theme.onAccent)
                .padding(.horizontal, 20)
                .frame(height: 42)
                .background(theme.accent)
                .clipShape(RoundedRectangle(cornerRadius: 11))
                .shadow(color: theme.accent.opacity(0.28), radius: 5, y: 3)
            }
            .buttonStyle(.plain)

            iconButton(model.bookmarks.contains(work.id) ? "bookmark.fill" : "bookmark",
                       tint: model.bookmarks.contains(work.id) ? theme.accent : theme.ink,
                       help: "Bookmark") {
                model.toggle(work.id, in: &model.bookmarks)
            }
            iconButton(model.downloaded.contains(work.id) ? "checkmark.circle" : "arrow.down.circle",
                       tint: model.downloaded.contains(work.id) ? theme.sage : theme.ink,
                       help: model.downloaded.contains(work.id) ? "Downloaded" : "Download for offline") {
                model.toggle(work.id, in: &model.downloaded)
            }

            Button {
                model.toggle(work.id, in: &model.kudos)
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: model.kudos.contains(work.id) ? "heart.fill" : "heart")
                        .font(.system(size: 14, weight: .semibold))
                    Text(model.kudos.contains(work.id) ? "Kudos left" : "Kudos")
                        .font(Font(MacFont.ui(14.5, weight: .bold)))
                }
                .foregroundStyle(model.kudos.contains(work.id) ? theme.accent : theme.ink)
                .padding(.horizontal, 20)
                .frame(height: 42)
                .background(theme.surface)
                .clipShape(RoundedRectangle(cornerRadius: 11))
                .overlay(RoundedRectangle(cornerRadius: 11).stroke(theme.line, lineWidth: 1))
            }
            .buttonStyle(.plain)
        }
    }

    private func iconButton(_ symbol: String, tint: Color, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(tint)
                .frame(width: 42, height: 42)
                .background(theme.surface)
                .clipShape(RoundedRectangle(cornerRadius: 11))
                .overlay(RoundedRectangle(cornerRadius: 11).stroke(theme.line, lineWidth: 1))
        }
        .buttonStyle(.plain)
        .help(help)
    }

    private var statGrid: some View {
        HStack(spacing: 1) {
            statCell(MacMockData.fmt(work.words), "Words")
            statCell("\(work.chapterCount)/\(work.complete ? String(work.totalChapters) : "?")", "Chapters")
            statCell(MacMockData.fmt(work.kudos), "Kudos")
            statCell(MacMockData.fmt(work.bookmarks), "Saved")
        }
        .background(theme.line)
        .clipShape(RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(theme.line, lineWidth: 1))
    }

    private func statCell(_ value: String, _ label: String) -> some View {
        VStack(spacing: 3) {
            Text(value)
                .font(Font(MacFont.serif(22, weight: .semibold)))
                .foregroundStyle(theme.ink)
            Text(label.uppercased())
                .font(Font(MacFont.ui(11, weight: .semibold)))
                .kerning(0.5)
                .foregroundStyle(theme.ink3)
        }
        .padding(.init(top: 15, leading: 8, bottom: 15, trailing: 8))
        .frame(maxWidth: .infinity)
        .background(theme.surface)
    }

    private var summaryBox: some View {
        VStack(alignment: .leading, spacing: 9) {
            Text("SUMMARY")
                .font(Font(MacFont.ui(11, weight: .bold)))
                .kerning(0.9)
                .foregroundStyle(theme.ink3)
            Text(work.summary)
                .font(Font(MacFont.serif(17)).italic())
                .lineSpacing(5)
                .foregroundStyle(theme.ink)
        }
        .padding(.init(top: 18, leading: 20, bottom: 18, trailing: 20))
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(theme.surface)
        .clipShape(RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(theme.line, lineWidth: 1))
    }

    private var tags: some View {
        FlowLayout(spacing: 7) {
            ForEach(work.tags, id: \.self) { tag in
                Text(tag)
                    .font(Font(MacFont.ui(12, weight: .medium)))
                    .foregroundStyle(theme.ink2)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
                    .background(theme.surface2)
                    .clipShape(Capsule())
            }
        }
    }

    private var chapters: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("CHAPTERS")
                .font(Font(MacFont.ui(12, weight: .bold)))
                .kerning(0.8)
                .foregroundStyle(theme.ink3)
                .padding(.bottom, 8)
            ForEach(0..<work.totalChapters, id: \.self) { index in
                chapterRow(index)
            }
        }
    }

    private func chapterRow(_ index: Int) -> some View {
        let number = index + 1
        let unposted = number > work.chapterCount
        let read = started && number < currentChapter
        let title = work.content.flatMap { index < $0.count ? $0[index].title : nil } ?? "Chapter \(number)"
        return Button {
            model.openReader(work.id, chapter: index)
        } label: {
            HStack(spacing: 12) {
                Group {
                    if read {
                        Image(systemName: "checkmark")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundStyle(theme.onAccent)
                            .frame(width: 26, height: 26)
                            .background(theme.accent)
                    } else {
                        Text("\(number)")
                            .font(Font(MacFont.ui(12, weight: .bold)))
                            .foregroundStyle(theme.ink3)
                            .frame(width: 26, height: 26)
                            .background(theme.surface2)
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: 8))
                Text(unposted ? "Chapter \(number)" : title)
                    .font(Font(MacFont.ui(14.5, weight: .medium)))
                    .foregroundStyle(read ? theme.ink3 : theme.ink)
                Spacer()
                if unposted {
                    Text("Not posted")
                        .font(Font(MacFont.ui(11)))
                        .foregroundStyle(theme.ink3)
                } else {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(theme.ink3)
                }
            }
            .padding(.init(top: 12, leading: 4, bottom: 12, trailing: 4))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(unposted)
        .opacity(unposted ? 0.4 : 1)
        .overlay(alignment: .bottom) { theme.line.frame(height: 1) }
    }
}
