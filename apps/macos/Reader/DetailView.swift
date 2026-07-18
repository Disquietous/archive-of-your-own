import SwiftUI

/// Work detail — the reading pane's master/detail "detail" state, backed by
/// the shared AppState. Centered ~720pt column per the handoff.
struct DetailView: View {
    @Bindable var theme: AppTheme
    @Bindable var appState: AppState
    @Bindable var model: MacAppModel
    let work: Work

    private var progress: Double { model.progress(for: work) }
    private var started: Bool { progress > 0 }
    private var currentChapter: Int { appState.progressMap[work.id]?.chapter ?? 1 }
    private var warnOK: Bool { work.warnings.contains("No Archive") }
    private var bookmarked: Bool { appState.bookmarkedWorkIDs.contains(work.id) }
    private var downloaded: Bool { appState.downloadedWorkIDs.contains(work.id) }
    private var hasKudos: Bool { appState.kudosGivenWorkIDs.contains(work.id) }

    @State private var showComments = false
    @State private var showBookmarkEdit = false

    var body: some View {
        let _ = theme.uiFontScale  // track app text size so fonts refresh live
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
                if !work.relationship.isEmpty {
                    Text(work.relationship)
                        .font(Font(MacFont.ui(14)))
                        .foregroundStyle(theme.ink3)
                        .padding(.bottom, 20)
                } else {
                    Spacer().frame(height: 20)
                }

                pills.padding(.bottom, 22)
                actions.padding(.bottom, appState.kudosFailedWorkID == work.id ? 8 : 26)
                if appState.kudosFailedWorkID == work.id {
                    Text("Couldn’t leave kudos — the archive rejected the request. Try again.")
                        .font(Font(MacFont.ui(12)))
                        .foregroundStyle(Color(hex: "CE514D"))
                        .padding(.bottom, 18)
                }
                statGrid.padding(.bottom, 24)
                if !work.summary.isEmpty {
                    summaryBox.padding(.bottom, 22)
                }
                if !work.tags.isEmpty {
                    tags.padding(.bottom, 26)
                }
                chapters
            }
            .padding(.init(top: 34, leading: 48, bottom: 60, trailing: 48))
            .frame(maxWidth: 720)
            .frame(maxWidth: .infinity)
        }
        .alert("Remove Synced Bookmark?", isPresented: pendingRemovalBinding) {
            Button("Remove Everywhere", role: .destructive) {
                appState.confirmBookmarkRemoval()
            }
            Button("Remove Locally Only") {
                if let id = appState.pendingBookmarkRemoval {
                    appState.bookmarkedWorkIDs.remove(id)
                    if let workId = UInt64(id) { appState.bridge.removeBookmark(workId) }
                    appState.pendingBookmarkRemoval = nil
                }
            }
            Button("Cancel", role: .cancel) {
                appState.cancelBookmarkRemoval()
            }
        } message: {
            Text("This bookmark is synced with your AO3 account. Remove it from AO3 as well, or only from this device?")
        }
        .sheet(isPresented: $showComments) {
            MacCommentsView(theme: theme, appState: appState,
                            workID: work.id,
                            chapterID: nil,
                            title: work.title,
                            subtitle: nil,
                            onClose: { showComments = false })
        }
        .sheet(isPresented: $showBookmarkEdit) {
            MacBookmarkEditView(theme: theme, appState: appState,
                                workID: work.id,
                                workTitle: work.title,
                                onClose: { showBookmarkEdit = false })
        }
    }

    private var pendingRemovalBinding: Binding<Bool> {
        Binding(get: { appState.pendingBookmarkRemoval != nil },
                set: { if !$0 { appState.cancelBookmarkRemoval() } })
    }

    private var pills: some View {
        FlowLayout(spacing: 8) {
            pill("\(work.rating.letter) · \(work.rating.rawValue)",
                 bg: theme.accent.opacity(0.14), fg: theme.accent)
            pill(warnOK ? "No warnings" : work.warnings,
                 icon: warnOK ? "checkmark.shield" : "eye",
                 bg: (warnOK ? theme.sage : theme.accent2).opacity(0.15),
                 fg: warnOK ? theme.sage : theme.accent2)
            pill(work.complete ? "Complete" : "Work in progress", bg: theme.surface2, fg: theme.ink2)
            if !work.updated.isEmpty {
                pill("Updated \(work.updated)", bg: theme.surface2, fg: theme.ink3)
            }
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

            iconButton(bookmarked ? "bookmark.fill" : "bookmark",
                       tint: bookmarked ? theme.accent : theme.ink,
                       help: "Bookmark") {
                appState.toggleBookmark(work.id)
            }
            if bookmarked {
                iconButton("square.and.pencil",
                           tint: theme.ink,
                           help: "Edit bookmark — notes, tags, sync to AO3") {
                    showBookmarkEdit = true
                }
            }
            iconButton(downloadSymbol,
                       tint: downloaded ? theme.sage : theme.ink,
                       help: downloaded ? "Downloaded" : "Download for offline") {
                appState.toggleDownload(work.id)
            }

            Button {
                appState.giveKudos(work.id)
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: hasKudos ? "heart.fill" : "heart")
                        .font(.system(size: 14, weight: .semibold))
                    Text(hasKudos ? "Kudos left" : "Kudos")
                        .font(Font(MacFont.ui(14.5, weight: .bold)))
                }
                .foregroundStyle(hasKudos ? theme.accent : theme.ink)
                .padding(.horizontal, 20)
                .frame(height: 42)
                .background(theme.surface)
                .clipShape(RoundedRectangle(cornerRadius: 11))
                .overlay(RoundedRectangle(cornerRadius: 11).stroke(theme.line, lineWidth: 1))
            }
            .buttonStyle(.plain)
            .disabled(hasKudos)
            .help(hasKudos ? "Kudos are permanent on AO3" : "Leave kudos on AO3")

            Button {
                showComments = true
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "bubble.right")
                        .font(.system(size: 14, weight: .semibold))
                    Text(work.comments > 0 ? "Comments · \(Fmt.k(work.comments))" : "Comments")
                        .font(Font(MacFont.ui(14.5, weight: .bold)))
                }
                .foregroundStyle(theme.ink)
                .padding(.horizontal, 20)
                .frame(height: 42)
                .background(theme.surface)
                .clipShape(RoundedRectangle(cornerRadius: 11))
                .overlay(RoundedRectangle(cornerRadius: 11).stroke(theme.line, lineWidth: 1))
            }
            .buttonStyle(.plain)
        }
    }

    private var downloadSymbol: String {
        if appState.isDownloading(work.id) { return "arrow.down.circle.dotted" }
        return downloaded ? "checkmark.circle" : "arrow.down.circle"
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
            statCell(Fmt.k(work.words), "Words")
            statCell("\(work.chapterCount)/\(work.complete ? String(work.totalChapters) : "?")", "Chapters")
            statCell(Fmt.k(work.kudos), "Kudos")
            statCell(Fmt.k(work.bookmarks), "Saved")
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
        // The summary is reading prose — honor the reader's typeface, size,
        // and spacing settings (scaled slightly down from chapter body text).
        let size = CGFloat(theme.fontSize) * 0.9
        return VStack(alignment: .leading, spacing: 9) {
            Text("SUMMARY")
                .font(Font(MacFont.ui(11, weight: .bold)))
                .kerning(0.9)
                .foregroundStyle(theme.ink3)
            Text(work.summary)
                .font(Font(MacFont.reading(named: theme.readingFont.fontName, size: size)).italic())
                .lineSpacing(size * (theme.readLeading - 1) * 0.45)
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
                Button {
                    model.searchTag(tag)
                } label: {
                    Text(tag)
                        .font(Font(MacFont.ui(12, weight: .medium)))
                        .foregroundStyle(theme.ink2)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 4)
                        .background(theme.surface2)
                        .clipShape(Capsule())
                }
                .buttonStyle(.plain)
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
            ForEach(0..<max(1, work.totalChapters), id: \.self) { index in
                chapterRow(index)
            }
        }
    }

    private func chapterRow(_ index: Int) -> some View {
        let number = index + 1
        let unposted = number > work.chapterCount
        let read = started && number < currentChapter
        let fetchedTitle = appState.chaptersForWork(work.id)
            .flatMap { index < $0.count ? $0[index].title : nil }
        let title = fetchedTitle?.isEmpty == false ? fetchedTitle! : "Chapter \(number)"
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
