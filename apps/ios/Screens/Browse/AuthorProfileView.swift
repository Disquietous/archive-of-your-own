import SwiftUI

/// An author's profile card over their three lists — Works, Bookmarks,
/// Collections — driven by the shared `AuthorProfileModel`. Local-first:
/// opening shows what the library has cached; AO3 is only touched by the
/// chrome's Refresh action, which walks every page of the active pane.
struct AuthorProfileView: View {
    @Environment(AppTheme.self) var theme
    @Environment(AppState.self) var state
    @Environment(NavigationState.self) var nav
    @Environment(AuthorProfileModel.self) var author

    let username: String
    /// Pane to land on (an opened link to a user's bookmarks, say); nil =
    /// the profile's default.
    var initialPane: AuthorProfileModel.Pane?

    /// Open once per screen instance: onAppear fires again when a work
    /// detail pushed on top is popped, and re-opening would cancel a crawl.
    @State var didOpen = false
    @State var avatarImage: UIImage?
    @State var pendingModeration: ModerationAction?
    /// The AO3 subscription change awaiting confirmation (true = subscribe).
    @State var newListFor: Work?
    @State var newListName = ""
    @State var exportedEpub: EpubExporter.Exported?
    @State var exportError: String?
    /// "Mark all as read" awaiting confirmation (true = mark, false = unmark).
    @State var pendingMarkAllRead: Bool?

    enum ModerationAction {
        case block, mute
    }

    var profile: UUserProfile? { state.userProfile(username) }

    /// This screen's model state only counts while the model is on this
    /// author — a stale model (another profile deeper in the stack) never
    /// bleeds into the rendering.
    var isCurrent: Bool { author.username == username }

    var works: [Work] { isCurrent ? author.works : [] }
    var allWorksFinished: Bool {
        !works.isEmpty && works.allSatisfy { state.finishedWorkIDs.contains($0.id) }
    }
    var bookmarks: [UBookmarkHit] { isCurrent ? author.bookmarks : [] }
    var collections: [UCollection] { isCurrent ? author.collections : [] }

    /// The active pane's tracked operation, for the request banner.
    var bannerOpID: UInt64? {
        guard isCurrent else { return nil }
        switch author.pane {
        case .works: return author.worksRefreshOp.opID
        case .bookmarks: return author.bookmarksRefreshOp.opID
        case .collections: return nil
        }
    }

    var paneBusy: Bool {
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

    var chromeSubtitle: String? {
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

}
