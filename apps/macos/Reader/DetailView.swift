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
    private var followingAuthor: Bool { model.followedAuthorNames.contains(work.author) }
    private var workSubscribed: Bool { appState.isSubscribedToWork(work.id) }

    @State private var showComments = false
    @State private var showBookmarkEdit = false
    @State private var showReadingLists = false

    private var inAnyReadingList: Bool {
        guard let id = UInt64(work.id) else { return false }
        return appState.readingLists.contains { appState.bridge.getReadingListItems($0.id).contains(id) }
    }

    var body: some View {
        let _ = theme.uiFontScale  // track app text size so fonts refresh live
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                Text(work.title)
                    .font(Font(MacFont.serif(38, weight: .bold)))
                    .foregroundStyle(theme.ink)
                    .lineSpacing(2)
                    .padding(.bottom, 10)
                HStack(spacing: 10) {
                    Button {
                        if followingAuthor {
                            model.unfollowAuthor(work.author)
                        } else {
                            model.followAuthor(work.author)
                        }
                    } label: {
                        (Text("by ").foregroundStyle(theme.ink2)
                            + Text(work.author).foregroundStyle(theme.accent).fontWeight(.semibold))
                            .font(Font(MacFont.ui(16)))
                    }
                    .buttonStyle(.plain)
                    .help(followingAuthor
                          ? "Unfollow \(work.author)"
                          : "Follow \(work.author) — adds them to Authors → Following")
                    if followingAuthor {
                        HStack(spacing: 4) {
                            Image(systemName: "checkmark")
                                .font(.system(size: 9, weight: .bold))
                            Text("Following")
                                .font(Font(MacFont.ui(11, weight: .semibold)))
                        }
                        .foregroundStyle(theme.sage)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(theme.sage.opacity(0.14))
                        .clipShape(Capsule())
                    }
                }
                .padding(.bottom, 10)
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(work.fandomList, id: \.self) { fandom in
                        Text(fandom)
                            .font(Font(MacFont.ui(13, weight: .bold)))
                            .foregroundStyle(theme.accent)
                    }
                }
                .padding(.bottom, 6)
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
            if appState.goneWorkIDs.contains(work.id) {
                pill("No longer on AO3", icon: "archivebox",
                     bg: theme.accent2.opacity(0.13), fg: theme.accent2)
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

            if UInt64(work.id) != nil {
                iconButton(inAnyReadingList ? "books.vertical.fill" : "books.vertical",
                           tint: inAnyReadingList ? theme.accent : theme.ink,
                           help: "Add to reading list") {
                    showReadingLists = true
                }
                .popover(isPresented: $showReadingLists, arrowEdge: .bottom) {
                    ReadingListPopover(theme: theme, appState: appState, work: work)
                }
            }

            iconButton(workSubscribed ? "bell.fill" : "bell",
                       tint: workSubscribed ? theme.accent : theme.ink,
                       help: appState.ao3Username == nil
                           ? "Sign in to subscribe to this work"
                           : (workSubscribed ? "Unsubscribe from this work on AO3"
                                             : "Subscribe to this work on AO3")) {
                appState.toggleWorkSubscription(work.id)
            }
            .disabled(appState.ao3Username == nil
                      || appState.subscriptionTogglingWorkIDs.contains(work.id))

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

/// Find-or-create reading list popover: type to filter the lists, click to
/// toggle membership, and when the typed name matches nothing, a Create row
/// makes the list with this work already in it.
private struct ReadingListPopover: View {
    @Bindable var theme: AppTheme
    @Bindable var appState: AppState
    let work: Work

    @State private var term = ""
    @FocusState private var searchFocused: Bool

    private var workId: UInt64? { UInt64(work.id) }

    private var filteredLists: [UReadingList] {
        let needle = term.trimmingCharacters(in: .whitespaces)
        guard !needle.isEmpty else { return appState.readingLists }
        return appState.readingLists.filter {
            $0.name.localizedCaseInsensitiveContains(needle)
        }
    }

    private var canCreateTyped: Bool {
        let needle = term.trimmingCharacters(in: .whitespaces)
        guard !needle.isEmpty else { return false }
        return !appState.readingLists.contains {
            $0.name.caseInsensitiveCompare(needle) == .orderedSame
        }
    }

    private func isMember(_ list: UReadingList) -> Bool {
        guard let workId else { return false }
        return appState.bridge.getReadingListItems(list.id).contains(workId)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("READING LISTS")
                .font(Font(MacFont.ui(10.5, weight: .bold)))
                .kerning(0.6)
                .foregroundStyle(theme.ink3)
                .padding(.init(top: 12, leading: 14, bottom: 8, trailing: 14))

            TextField("Find or create a list…", text: $term)
                .textFieldStyle(.plain)
                .font(Font(MacFont.ui(13)))
                .foregroundStyle(theme.ink)
                .padding(.horizontal, 10)
                .frame(height: 30)
                .background(theme.surface2)
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .padding(.horizontal, 12)
                .focused($searchFocused)
                .onSubmit { createTypedIfPossible() }

            ScrollView {
                VStack(spacing: 0) {
                    ForEach(filteredLists, id: \.id) { list in
                        listRow(list)
                    }
                    if canCreateTyped {
                        createRow
                    } else if filteredLists.isEmpty {
                        Text("No lists yet — type a name to create one.")
                            .font(Font(MacFont.ui(12)))
                            .foregroundStyle(theme.ink3)
                            .padding(14)
                    }
                }
            }
            .frame(maxHeight: 260)
            .padding(.top, 6)
            .padding(.bottom, 8)
        }
        .frame(width: 280)
        .background(theme.surface)
        .onAppear { searchFocused = true }
    }

    private func listRow(_ list: UReadingList) -> some View {
        let member = isMember(list)
        return Button {
            guard workId != nil else { return }
            if member {
                appState.removeFromReadingList(list.id, workId: work.id)
            } else {
                appState.addToReadingList(list.id, workId: work.id)
            }
        } label: {
            HStack(spacing: 10) {
                Image(systemName: "books.vertical")
                    .font(.system(size: 12, weight: .medium))
                    .frame(width: 16)
                    .foregroundStyle(theme.ink3)
                Text(list.name)
                    .font(Font(MacFont.ui(13, weight: .medium)))
                    .foregroundStyle(theme.ink)
                    .lineLimit(1)
                Spacer(minLength: 8)
                if member {
                    Image(systemName: "checkmark")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(theme.accent)
                }
            }
            .padding(.horizontal, 14)
            .frame(height: 32)
            .contentShape(Rectangle())
        }
        .buttonStyle(SidebarItemStyle(hover: theme.ink.opacity(0.06)))
        .help(member ? "Remove from “\(list.name)”" : "Add to “\(list.name)”")
    }

    private var createRow: some View {
        Button {
            createTypedIfPossible()
        } label: {
            HStack(spacing: 10) {
                Image(systemName: "plus")
                    .font(.system(size: 11, weight: .semibold))
                    .frame(width: 16)
                    .foregroundStyle(theme.accent)
                Text("Create “\(term.trimmingCharacters(in: .whitespaces))”")
                    .font(Font(MacFont.ui(13, weight: .semibold)))
                    .foregroundStyle(theme.accent)
                    .lineLimit(1)
                Spacer(minLength: 8)
            }
            .padding(.horizontal, 14)
            .frame(height: 32)
            .contentShape(Rectangle())
        }
        .buttonStyle(SidebarItemStyle(hover: theme.ink.opacity(0.06)))
    }

    private func createTypedIfPossible() {
        guard canCreateTyped else { return }
        let name = term.trimmingCharacters(in: .whitespaces)
        let listId = appState.createReadingList(name)
        if listId >= 0 {
            appState.addToReadingList(listId, workId: work.id)
        }
        term = ""
    }
}
