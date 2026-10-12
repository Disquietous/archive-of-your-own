import SwiftUI

/// An author's profile card over their three lists — Works, Bookmarks,
/// Collections — driven by the shared `AuthorProfileModel`. Local-first:
/// opening shows what the library has cached; AO3 is only touched by the
/// chrome's Refresh action, which walks every page of the active pane.
struct AuthorProfileView: View {
    @Environment(AppTheme.self) private var theme
    @Environment(AppState.self) private var state
    @Environment(NavigationState.self) private var nav
    @Environment(AuthorProfileModel.self) private var author

    let username: String
    /// Pane to land on (an opened link to a user's bookmarks, say); nil =
    /// the profile's default.
    var initialPane: AuthorProfileModel.Pane?

    /// Open once per screen instance: onAppear fires again when a work
    /// detail pushed on top is popped, and re-opening would cancel a crawl.
    @State private var didOpen = false
    @State private var avatarImage: UIImage?
    @State private var pendingModeration: ModerationAction?
    /// The AO3 subscription change awaiting confirmation (true = subscribe).
    @State private var newListFor: Work?
    @State private var newListName = ""
    @State private var exportedEpub: EpubExporter.Exported?
    @State private var exportError: String?
    /// "Mark all as read" awaiting confirmation (true = mark, false = unmark).
    @State private var pendingMarkAllRead: Bool?

    private enum ModerationAction {
        case block, mute
    }

    private var profile: UUserProfile? { state.userProfile(username) }

    /// This screen's model state only counts while the model is on this
    /// author — a stale model (another profile deeper in the stack) never
    /// bleeds into the rendering.
    private var isCurrent: Bool { author.username == username }

    private var works: [Work] { isCurrent ? author.works : [] }
    private var allWorksFinished: Bool {
        !works.isEmpty && works.allSatisfy { state.finishedWorkIDs.contains($0.id) }
    }
    private var bookmarks: [UBookmarkHit] { isCurrent ? author.bookmarks : [] }
    private var collections: [UCollection] { isCurrent ? author.collections : [] }

    /// The active pane's tracked operation, for the request banner.
    private var bannerOpID: UInt64? {
        guard isCurrent else { return nil }
        switch author.pane {
        case .works: return author.worksRefreshOp.opID
        case .bookmarks: return author.bookmarksRefreshOp.opID
        case .collections: return nil
        }
    }

    private var paneBusy: Bool {
        guard isCurrent else { return false }
        switch author.pane {
        case .works: return author.isLoadingWorks
        case .bookmarks: return author.isLoadingBookmarks
        case .collections: return author.isLoadingCollections
        }
    }

    var body: some View {
        ZStack(alignment: .top) {
            ScrollView {
                VStack(alignment: .leading, spacing: theme.rowGap) {
                    profileHeader
                    paneSwitcher
                    paneContent
                }
                .padding(.horizontal, theme.pad)
                .padding(.bottom, 24)
            }
            .contentMargins(.top, ScreenChromeMetrics.height, for: .scrollContent)

            VStack(spacing: 8) {
                ScreenChrome(title: profile?.username ?? username, subtitle: chromeSubtitle) {
                    paneMenu
                }
                if let opID = bannerOpID {
                    RequestProgressBanner(opID: opID) {
                        cancelActivePane(opID)
                    }
                    .padding(.horizontal, theme.pad)
                    .transition(.move(edge: .top).combined(with: .opacity))
                }
            }
            .animation(.easeInOut(duration: 0.2), value: bannerOpID)
        }
        .libraryScreen()
        .onAppear {
            guard !didOpen else { return }
            didOpen = true
            author.open(username)
            if let initialPane { author.showPane(initialPane) }
        }
        .task {
            await loadAvatar()
        }
        .confirmationDialog(
            moderationTitle,
            isPresented: Binding(
                get: { pendingModeration != nil },
                set: { if !$0 { pendingModeration = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button(moderationButtonLabel, role: .destructive) {
                switch pendingModeration {
                case .block: state.toggleAuthorBlock(username)
                case .mute: state.toggleAuthorMute(username)
                case nil: break
                }
                pendingModeration = nil
            }
            Button("Cancel", role: .cancel) { pendingModeration = nil }
        } message: {
            Text(moderationMessage)
        }
        .confirmationDialog(
            pendingMarkAllRead == true ? "Mark all as read?" : "Unmark all as read?",
            isPresented: Binding(
                get: { pendingMarkAllRead != nil },
                set: { if !$0 { pendingMarkAllRead = nil } }
            ),
            titleVisibility: .visible
        ) {
            // The flag is manual-only, so a whole-list rewrite always
            // passes through this confirmed branch.
            Button(pendingMarkAllRead == true ? "Mark All as Read" : "Unmark All",
                   role: pendingMarkAllRead == true ? nil : .destructive) {
                if let mark = pendingMarkAllRead {
                    state.setFinished(works.map(\.id), finished: mark)
                }
                pendingMarkAllRead = nil
            }
            Button("Cancel", role: .cancel) { pendingMarkAllRead = nil }
        } message: {
            let count = works.count == 1 ? "1 work" : "\(works.count) works"
            Text(pendingMarkAllRead == true
                 ? "This flags all \(count) in this list as finished reading."
                 : "This clears the finished-reading flag on all \(count) in this list.")
        }
        .sheet(item: $exportedEpub) { exported in
            ShareSheet(items: [exported.url])
                .presentationDetents([.medium, .large])
        }
        .alert("Couldn’t export EPUB", isPresented: Binding(
            get: { exportError != nil },
            set: { if !$0 { exportError = nil } })) {
            Button("OK", role: .cancel) { exportError = nil }
        } message: {
            Text(exportError ?? "")
        }
        .alert("New Reading List", isPresented: Binding(
            get: { newListFor != nil },
            set: { if !$0 { newListFor = nil; newListName = "" } })) {
            TextField("List name", text: $newListName)
            Button("Create") {
                let name = newListName.trimmingCharacters(in: .whitespaces)
                if let work = newListFor, !name.isEmpty {
                    let listId = state.createReadingList(name)
                    if listId >= 0 { state.addToReadingList(listId, workId: work.id) }
                }
                newListFor = nil
                newListName = ""
            }
            Button("Cancel", role: .cancel) { newListFor = nil; newListName = "" }
        } message: {
            if let work = newListFor {
                Text("“\(work.title)” will be added to the new list.")
            }
        }
    }

    private var chromeSubtitle: String? {
        guard isCurrent else { return nil }
        switch author.pane {
        case .works:
            let count = works.count
            let stored = count == 1 ? "1 stored work" : "\(count) stored works"
            if let crawledAt = author.worksCrawledAt, !crawledAt.isEmpty,
               let rel = DBTimestamp.relative(crawledAt) {
                return "\(stored) · refreshed \(rel)"
            }
            return stored
        case .bookmarks:
            let count = bookmarks.count
            return count == 1 ? "1 bookmark" : "\(count) bookmarks"
        case .collections:
            let count = collections.count
            return count == 1 ? "1 collection" : "\(count) collections"
        }
    }

    // MARK: - Refresh / cancel

    private func refreshOrCancelActivePane() {
        switch author.pane {
        case .works:
            if author.isLoadingWorks {
                author.cancelWorksRefresh()
                if let opID = author.worksRefreshOp.opID { state.bridge.cancelOperation(opID) }
            } else {
                author.refreshWorks()
            }
        case .bookmarks:
            if author.isLoadingBookmarks {
                if let opID = author.bookmarksRefreshOp.opID { state.bridge.cancelOperation(opID) }
            } else {
                author.refreshBookmarks()
            }
        case .collections:
            if !author.isLoadingCollections {
                author.refreshCollections()
            }
        }
    }

    /// The active pane's AO3 actions — full-list refreshes are long
    /// crawls, so they sit in this menu rather than on a one-tap button.
    private var paneMenu: some View {
        Menu {
            if paneBusy {
                Button { refreshOrCancelActivePane() } label: {
                    Label("Cancel Refresh", systemImage: "xmark.circle")
                }
            } else {
                if author.pane == .works, let stop = author.worksCrawlStop {
                    Button { author.refreshWorks(resume: true) } label: {
                        Label("Resume (page \(stop.nextPage) of \(stop.totalPages))", systemImage: "arrow.clockwise")
                    }
                }
                Button { refreshOrCancelActivePane() } label: {
                    Label(refreshTitle, systemImage: "arrow.clockwise")
                }
            }
        } label: {
            Image(systemName: "ellipsis")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(theme.ink2)
                .frame(width: 36, height: 36)
        }
        .accessibilityLabel("More")
    }

    private var refreshTitle: String {
        switch author.pane {
        case .works: author.worksCrawlStop == nil ? "Refresh Works from AO3" : "Refresh All Works from AO3"
        case .bookmarks: "Refresh Bookmarks from AO3"
        case .collections: "Refresh Collections from AO3"
        }
    }

    private func cancelActivePane(_ opID: UInt64) {
        state.bridge.cancelOperation(opID)
        if author.pane == .works { author.cancelWorksRefresh() }
    }

    // MARK: - Profile header

    @ViewBuilder
    private var profileHeader: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .center, spacing: 12) {
                avatarView

                VStack(alignment: .leading, spacing: 3) {
                    Text(profile?.username ?? username)
                        .font(Typography.browseTitle())
                        .foregroundStyle(theme.ink)
                        .lineLimit(1)

                    if let profile {
                        if !profile.joined.isEmpty {
                            Text(profile.location.isEmpty
                                 ? "Joined \(profile.joined)"
                                 : "Joined \(profile.joined) · \(profile.location)")
                                .font(Typography.uiCaption())
                                .foregroundStyle(theme.ink3)
                        }
                        if profile.pseuds.count > 1 {
                            Text("Pseuds: \(profile.pseuds.joined(separator: ", "))")
                                .font(Typography.uiCaption())
                                .foregroundStyle(theme.ink3)
                                .lineLimit(2)
                        }
                    } else if state.userProfileLoading.contains(username.lowercased()) {
                        HStack(spacing: 6) {
                            ProgressView().controlSize(.mini).tint(theme.ink3)
                            Text("Loading profile…")
                                .font(Typography.uiCaption())
                                .foregroundStyle(theme.ink3)
                        }
                    }
                }

                Spacer()

                // Followed / Subscribed — following needs no account.
                FollowBellMenu(target: .author(username), glyphSize: 16, hitSize: 36)
                if state.ao3Username != nil {
                    moderationMenu
                }
            }

            if let profile {
                statsRow(profile)

                if profile.blocked || profile.muted {
                    HStack(spacing: 6) {
                        if profile.blocked { statusBadge("Blocked") }
                        if profile.muted { statusBadge("Muted") }
                    }
                }

                let bio = ParsedContentBlock.fromJSON(profile.bioJson)
                if !bio.isEmpty {
                    ContentBlockView(blocks: bio, compact: true)
                }
            } else if let profileError = state.userProfileError(username) {
                Text("Couldn’t load profile: \(profileError)")
                    .font(Typography.uiCaption())
                    .foregroundStyle(theme.ink3)
            }

        }
        .padding(.top, 8)
        .padding(.bottom, 4)
    }

    private var avatarView: some View {
        Group {
            if let avatarImage {
                Image(uiImage: avatarImage)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            } else {
                Circle()
                    .fill(theme.surface2)
                    .overlay {
                        Text(String(username.prefix(1)).uppercased())
                            .font(.custom("HankenGrotesk", size: 22).weight(.bold))
                            .foregroundStyle(theme.ink3)
                    }
            }
        }
        .frame(width: 56, height: 56)
        .clipShape(Circle())
    }

    private var moderationMenu: some View {
        // Block/mute need the live state before they can flip it.
        let haveState = profile != nil
        return Menu {
            Button(profile?.blocked == true ? "Unblock \(username)" : "Block \(username)…",
                   role: profile?.blocked == true ? nil : .destructive) {
                if profile?.blocked == true {
                    state.toggleAuthorBlock(username)
                } else {
                    pendingModeration = .block
                }
            }
            .disabled(!haveState || state.isUserActionBusy("block", username))

            Button(profile?.muted == true ? "Unmute \(username)" : "Mute \(username)…",
                   role: profile?.muted == true ? nil : .destructive) {
                if profile?.muted == true {
                    state.toggleAuthorMute(username)
                } else {
                    pendingModeration = .mute
                }
            }
            .disabled(!haveState || state.isUserActionBusy("mute", username))
        } label: {
            Image(systemName: "ellipsis")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(theme.ink2)
                .frame(width: 36, height: 36)
        }
    }

    private func statsRow(_ profile: UUserProfile) -> some View {
        let stats: [(String, UInt32)] = [
            ("Works", profile.worksCount),
            ("Series", profile.seriesCount),
            ("Bookmarks", profile.bookmarksCount),
            ("Collections", profile.collectionsCount),
            ("Gifts", profile.giftsCount),
        ]
        return Text(stats.map { "\($0.0) \($0.1)" }.joined(separator: " · "))
            .font(Typography.uiCaption())
            .foregroundStyle(theme.ink2)
    }

    private func statusBadge(_ label: String) -> some View {
        Text(label)
            .font(Typography.uiSmall())
            .foregroundStyle(theme.ink2)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(Capsule().fill(theme.surface2))
    }

    private var moderationTitle: String {
        switch pendingModeration {
        case .block: "Block \(username)?"
        case .mute: "Mute \(username)?"
        case nil: ""
        }
    }

    private var moderationButtonLabel: String {
        switch pendingModeration {
        case .block: "Block"
        case .mute: "Mute"
        case nil: ""
        }
    }

    private var moderationMessage: String {
        switch pendingModeration {
        case .block:
            "\(username) won’t be able to comment on your works or reply to your comments on AO3."
        case .mute:
            "You won’t see \(username)’s works, bookmarks, or comments while browsing AO3 signed in."
        case nil: ""
        }
    }

    private func loadAvatar() async {
        guard avatarImage == nil else { return }
        if let cached = state.authorAvatars[username], let image = UIImage(data: cached) {
            avatarImage = image
            return
        }
        if let data = try? await state.bridge.fetchAuthorAvatar(username),
           let image = UIImage(data: data) {
            state.authorAvatars[username] = data
            avatarImage = image
        }
    }

    // MARK: - Panes

    private var paneSwitcher: some View {
        SegmentedControlView(
            selection: Binding(
                get: { isCurrent ? author.pane : .works },
                set: { author.showPane($0) }
            ),
            items: [
                (key: AuthorProfileModel.Pane.works, label: paneLabel("Works", profile?.worksCount)),
                (key: AuthorProfileModel.Pane.bookmarks, label: paneLabel("Bookmarks", profile?.bookmarksCount)),
                (key: AuthorProfileModel.Pane.collections, label: paneLabel("Collections", profile?.collectionsCount)),
            ]
        )
    }

    private func paneLabel(_ name: String, _ count: UInt32?) -> String {
        guard let count, count > 0 else { return name }
        return "\(name) · \(count)"
    }

    @ViewBuilder
    private var paneContent: some View {
        if isCurrent {
            switch author.pane {
            case .works: worksPane
            case .bookmarks: bookmarksPane
            case .collections: collectionsPane
            }
        }
    }

    // MARK: Works

    @ViewBuilder
    private var worksPane: some View {
        if author.isLoadingWorks {
            HStack(spacing: 10) {
                ProgressView().controlSize(.small).tint(theme.ink3)
                Text(author.worksFetchStatus ?? "Fetching works from AO3…")
                    .font(.custom("HankenGrotesk", size: 12).weight(.medium))
                    .foregroundStyle(theme.ink3)
                Spacer()
                Button("Cancel") {
                    author.cancelWorksRefresh()
                    if let opID = author.worksRefreshOp.opID { state.bridge.cancelOperation(opID) }
                }
                .font(Typography.smallButtonLabel())
                .foregroundStyle(theme.accent)
                .buttonStyle(ButtonPressStyle())
            }
        } else if let error = author.worksError {
            NetworkErrorView(message: error, onRetry: { author.refreshWorks(resume: author.worksCrawlStop != nil) })
        } else if let stop = author.worksCrawlStop {
            CrawlStoppedRow(stop: stop) { author.refreshWorks(resume: true) }
        } else if author.worksCrawledAt == nil || author.worksCrawledAt?.isEmpty == true {
            fetchButton("Fetch complete works list from AO3") { author.refreshWorks() }
        }

        if works.isEmpty {
            if !author.isLoadingWorks && author.worksError == nil {
                EmptyStateView(systemImage: "doc.text",
                               title: "No stored works",
                               subtitle: "Refresh to fetch \(username)’s complete works list from AO3.")
                    .padding(.top, 24)
            }
        } else {
            markAllReadToggle
            LazyVStack(spacing: theme.rowGap) {
                ForEach(works) { work in
                    WorkCardView(
                        work: work,
                        blurExplicit: state.hideExplicit && work.rating == .explicit,
                        isRemoved: state.goneWorkIDs.contains(work.id),
                        onTap: { nav.openWork(work.id) }
                    )
                    .contextMenu {
                        WorkRowMenu(work: work, onNewReadingList: { newListFor = $0 },
                                    onExportEpub: { exportEpub($0) })
                    }
                }
            }
        }
    }

    // MARK: Bookmarks

    @ViewBuilder
    private var bookmarksPane: some View {
        if bookmarks.isEmpty {
            if author.isLoadingBookmarks {
                HStack(spacing: 10) {
                    ProgressView().controlSize(.small).tint(theme.ink3)
                    Text("Fetching bookmarks from AO3…")
                        .font(.custom("HankenGrotesk", size: 12).weight(.medium))
                        .foregroundStyle(theme.ink3)
                    Spacer()
                }
            } else if let error = author.bookmarksError {
                NetworkErrorView(message: error, onRetry: { author.loadMoreBookmarks() })
            } else {
                EmptyStateView(systemImage: "bookmark",
                               title: "No bookmarks in your library",
                               subtitle: "Refresh to fetch \(username)’s public bookmarks from AO3.")
                    .padding(.top, 24)
            }
        } else {
            LazyVStack(spacing: theme.rowGap) {
                ForEach(bookmarks, id: \.targetKey) { hit in
                    BookmarkHitCard(hit: hit, onNewReadingList: { newListFor = $0 },
                                    onExportEpub: { exportEpub($0) })
                }
            }
            listFooter(isLoading: author.isLoadingBookmarks, error: author.bookmarksError,
                       hasNext: author.bookmarksHasNext) { author.loadMoreBookmarks() }
        }
    }

    // MARK: Collections

    @ViewBuilder
    private var collectionsPane: some View {
        if collections.isEmpty {
            if author.isLoadingCollections {
                HStack(spacing: 10) {
                    ProgressView().controlSize(.small).tint(theme.ink3)
                    Text("Fetching collections from AO3…")
                        .font(.custom("HankenGrotesk", size: 12).weight(.medium))
                        .foregroundStyle(theme.ink3)
                    Spacer()
                }
            } else if let error = author.collectionsError {
                NetworkErrorView(message: error, onRetry: { author.loadMoreCollections() })
            } else {
                EmptyStateView(systemImage: "square.grid.2x2",
                               title: "No collections in your library",
                               subtitle: "Refresh to fetch \(username)’s collections from AO3.")
                    .padding(.top, 24)
            }
        } else {
            LazyVStack(spacing: theme.rowGap) {
                ForEach(collections, id: \.name) { collection in
                    CollectionCardView(collection: collection) {
                        nav.openCollection(name: collection.name,
                                           title: collection.title.isEmpty ? collection.name : collection.title)
                    }
                }
            }
            listFooter(isLoading: author.isLoadingCollections, error: author.collectionsError,
                       hasNext: author.collectionsHasNext) { author.loadMoreCollections() }
        }
    }

    // MARK: Shared pieces

    @ViewBuilder
    private func listFooter(isLoading: Bool, error: String?, hasNext: Bool,
                            loadMore: @escaping () -> Void) -> some View {
        if isLoading {
            HStack(spacing: 8) {
                ProgressView().controlSize(.small).tint(theme.ink3)
                Text("Loading more…")
                    .font(Typography.uiSmall())
                    .foregroundStyle(theme.ink3)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 12)
        } else if let error {
            NetworkErrorView(message: error, onRetry: loadMore)
        } else if hasNext {
            Button(action: loadMore) {
                Text("Load more")
                    .font(Typography.smallButtonLabel())
                    .foregroundStyle(theme.accent)
                    .frame(maxWidth: .infinity)
                    .frame(height: 44)
                    .background(
                        RoundedRectangle(cornerRadius: Radius.button)
                            .stroke(theme.line, lineWidth: 1)
                    )
            }
            .buttonStyle(ButtonPressStyle())
        }
    }

    /// Toggle above the works list: mark every listed work as finished, or
    /// unmark them all once they are. Both directions confirm first.
    private var markAllReadToggle: some View {
        let all = allWorksFinished
        return Button {
            pendingMarkAllRead = !all
        } label: {
            HStack(spacing: 8) {
                Image(systemName: all ? "checkmark.circle.fill" : "checkmark.circle")
                    .font(.system(size: 13, weight: .semibold))
                Text(all ? "All marked as read" : "Mark all as read")
                    .font(Typography.smallButtonLabel())
                Spacer()
            }
            .foregroundStyle(all ? theme.sage : theme.ink2)
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .contentShape(Rectangle())
        }
        .buttonStyle(ButtonPressStyle())
    }

    private func fetchButton(_ label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: "arrow.clockwise")
                    .font(.system(size: 13, weight: .semibold))
                Text(label)
                    .font(Typography.smallButtonLabel())
                Spacer()
            }
            .foregroundStyle(theme.accent)
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(
                RoundedRectangle(cornerRadius: Radius.smallButton)
                    .stroke(theme.accent, lineWidth: 1)
            )
        }
        .buttonStyle(ButtonPressStyle())
    }

    private func exportEpub(_ work: Work) {
        do {
            exportedEpub = try EpubExporter.export(work: work, appState: state)
        } catch {
            exportError = error.localizedDescription
        }
    }
}

/// One public-bookmark hit: the bookmarked work's card (or a series card)
/// with the bookmarker's own note, tags and rec mark underneath.
struct BookmarkHitCard: View {
    @Environment(AppTheme.self) private var theme
    @Environment(AppState.self) private var state
    @Environment(NavigationState.self) private var nav

    let hit: UBookmarkHit
    var onNewReadingList: ((Work) -> Void)?
    var onExportEpub: ((Work) -> Void)?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let summary = hit.work {
                let work = state.work(byID: String(summary.id)) ?? AppState.workFromSummary(summary)
                WorkCardView(
                    work: work,
                    blurExplicit: state.hideExplicit && work.rating == .explicit,
                    isRemoved: state.goneWorkIDs.contains(work.id),
                    onTap: { nav.openWork(work.id) }
                )
                .contextMenu {
                    WorkRowMenu(work: work, onNewReadingList: onNewReadingList,
                                onExportEpub: onExportEpub)
                }
            } else if let series = hit.series {
                seriesCard(series)
            }

            if hit.mystery && !hit.mysteryCollectionTitle.isEmpty {
                Text("Part of \(hit.mysteryCollectionTitle) — not yet revealed")
                    .font(Typography.uiCaption())
                    .foregroundStyle(theme.ink3)
            }

            bookmarkerLine
        }
    }

    @ViewBuilder
    private var bookmarkerLine: some View {
        let hasMeta = hit.rec || !hit.note.isEmpty || !hit.tags.isEmpty || !hit.dateBookmarked.isEmpty
        if hasMeta {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    Image(systemName: hit.rec ? "hand.thumbsup.fill" : "bookmark")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(hit.rec ? theme.accent : theme.ink3)
                    Text(hit.rec ? "Recommended" : "Bookmarked")
                        .font(Typography.uiSmall())
                        .foregroundStyle(theme.ink2)
                    if !hit.dateBookmarked.isEmpty {
                        Text("· \(hit.dateBookmarked)")
                            .font(Typography.uiSmall())
                            .foregroundStyle(theme.ink3)
                    }
                }
                if !hit.note.isEmpty {
                    Text(hit.note)
                        .font(Typography.summaryBody())
                        .foregroundStyle(theme.ink2)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if !hit.tags.isEmpty {
                    FlowLayout(spacing: 6) {
                        ForEach(hit.tags, id: \.self) { tag in
                            Text(tag)
                                .font(Typography.uiSmall())
                                .foregroundStyle(theme.ink2)
                                .lineLimit(1)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 3)
                                .background(Capsule().fill(theme.surface2))
                        }
                    }
                }
            }
            .padding(.horizontal, 4)
        }
    }

    private func seriesCard(_ series: USeriesSummary) -> some View {
        Button {
            nav.openSubscriptionWorks(id: String(series.id), name: series.name, subType: "series")
        } label: {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    Image(systemName: "books.vertical")
                        .font(.system(size: 11, weight: .semibold))
                    Text("SERIES")
                        .font(.custom("HankenGrotesk", size: 11.5).weight(.semibold))
                        .tracking(0.5)
                }
                .foregroundStyle(theme.ink3)

                Text(series.name)
                    .font(Typography.workTitle())
                    .foregroundStyle(theme.ink)
                    .multilineTextAlignment(.leading)
                    .lineLimit(2)

                if !series.authors.isEmpty {
                    Text("by \(series.authors.joined(separator: ", "))")
                        .font(Typography.uiCaption())
                        .foregroundStyle(theme.accent)
                }

                if !series.summary.isEmpty {
                    Text(series.summary)
                        .font(Typography.summaryBody())
                        .foregroundStyle(theme.ink2)
                        .multilineTextAlignment(.leading)
                        .lineLimit(3)
                }

                Text(seriesStats(series))
                    .font(Typography.uiCaption())
                    .foregroundStyle(theme.ink3)
            }
            .padding(theme.cardPad)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(theme.surface)
            .clipShape(RoundedRectangle(cornerRadius: Radius.card))
            .overlay(
                RoundedRectangle(cornerRadius: Radius.card)
                    .stroke(theme.line, lineWidth: 1)
            )
        }
        .buttonStyle(CardPressStyle())
    }

    private func seriesStats(_ series: USeriesSummary) -> String {
        var parts: [String] = []
        parts.append(series.workCount == 1 ? "1 work" : "\(series.workCount) works")
        parts.append("\(Int(series.wordCount).abbreviated) words")
        parts.append(series.complete ? "Complete" : "In progress")
        if !series.dateUpdated.isEmpty { parts.append("Updated \(series.dateUpdated)") }
        return parts.joined(separator: " · ")
    }
}
