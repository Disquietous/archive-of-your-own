import SwiftUI

/// Routes a Library hub section to its screen. The work-list sections
/// configure one `WorkListScreen`; the others have their own screens.
struct LibrarySectionScreen: View {
    @Environment(AppTheme.self) private var theme
    @Environment(AppState.self) private var state
    @Environment(NavigationState.self) private var nav
    @Environment(LibraryListModel.self) private var lists

    let section: LibrarySection

    var body: some View {
        switch section {
        case .reading: currentlyReading
        case .history: history
        case .whatsNew: whatsNew
        case .bookmarks: bookmarks
        case .downloads: downloads
        case .readingLists: ReadingListsScreen()
        case .fandoms: FandomsScreen()
        case .authors: AuthorsScreen()
        case .subscriptions: SubscriptionsScreen()
        case .inbox: InboxView()
        case .stats: StatsScreen()
        case .search, .authorWorks, .settings, .browse:
            // Tabs, not hub sections.
            EmptyView()
        }
    }

    // MARK: - Currently Reading

    private var currentlyReading: some View {
        CurrentlyReadingScreen()
    }

    // MARK: - History

    private var history: some View {
        HistoryScreen()
    }

    // MARK: - What's New

    private var whatsNew: some View {
        WhatsNewScreen()
    }

    // MARK: - Bookmarks

    private var bookmarks: some View {
        BookmarksScreen()
    }

    // MARK: - Offline

    private var downloads: some View {
        WorkListScreen(
            section: .downloads,
            title: "Offline",
            rawWorks: { state.downloadedWorkIDs.compactMap { state.work(byID: $0) }
                .sorted { $0.title < $1.title } },
            empty: .init(systemImage: "arrow.down.circle", title: "No downloads",
                         subtitle: "Works you download will appear here for offline reading."),
            swipe: .init(label: "Delete", systemImage: "trash") { work in
                if state.downloadedWorkIDs.contains(work.id) { state.toggleDownload(work.id) }
            }
        )
    }
}

// MARK: - Currently Reading

private struct CurrentlyReadingScreen: View {
    @Environment(AppState.self) private var state
    @Environment(NavigationState.self) private var nav

    @State private var confirmRemoveAll = false

    var body: some View {
        WorkListScreen(
            section: .reading,
            title: "Currently Reading",
            rawWorks: { state.currentlyReading },
            empty: .init(systemImage: "book", title: "Nothing in progress",
                         subtitle: "Works you start reading keep their place here."),
            swipe: .init(label: "Remove", systemImage: "minus.circle") { work in
                state.resetProgress(work.id)
            },
            menuItems: AnyView(
                Button(role: .destructive) {
                    confirmRemoveAll = true
                } label: {
                    Label("Remove All", systemImage: "trash")
                }
            )
        )
        .confirmationDialog("Remove every work from Currently Reading?",
                            isPresented: $confirmRemoveAll, titleVisibility: .visible) {
            Button("Remove All", role: .destructive) { state.removeAllCurrentlyReading() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Saved reading positions are cleared. Works stay in your library.")
        }
    }
}

// MARK: - History

private struct HistoryScreen: View {
    @Environment(AppState.self) private var state

    @State private var confirmClear = false

    var body: some View {
        WorkListScreen(
            section: .history,
            title: "History",
            rawWorks: { state.history.compactMap { state.work(byID: $0) } },
            empty: .init(systemImage: "clock", title: "Nothing read yet",
                         subtitle: "Your reading history stays on this device, encrypted."),
            menuItems: AnyView(
                Button(role: .destructive) {
                    confirmClear = true
                } label: {
                    Label("Clear History", systemImage: "trash")
                }
            )
        )
        .confirmationDialog("Clear reading history?", isPresented: $confirmClear,
                            titleVisibility: .visible) {
            Button("Clear History", role: .destructive) { state.clearHistory() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Removes every work from your reading history on this device.")
        }
    }
}

// MARK: - What's New

private struct WhatsNewScreen: View {
    @Environment(AppState.self) private var state
    @Environment(NavigationState.self) private var nav
    @Environment(LibraryListModel.self) private var lists

    @State private var confirmClear = false
    /// Pins freeze per visit; a detail pushed and popped is the same visit.
    @State private var didResetPins = false

    var body: some View {
        WorkListScreen(
            section: .whatsNew,
            title: "What’s New",
            rawWorks: { state.newWorkIDs.compactMap { state.work(byID: $0) } },
            empty: .init(systemImage: "bell.badge", title: "Nothing new",
                         subtitle: state.ao3Username == nil
                            ? "Sign in and subscribe on AO3 — updates land here after a check."
                            : "Updates to the works and authors you follow land here after a check."),
            marksNew: true,
            swipe: .init(label: "Remove", systemImage: "minus.circle") { work in
                state.removeNewWork(work.id)
            },
            onOpen: { work in
                state.markNewWorkSeen(work.id)
                nav.openWork(work.id)
            },
            menuItems: AnyView(Group {
                Button {
                    Task { await state.checkSubscriptions(force: true) }
                } label: {
                    Label("Check Now", systemImage: "arrow.clockwise")
                }
                .disabled(state.isCheckingSubscriptions || state.ao3Username == nil)
                Button(role: .destructive) {
                    confirmClear = true
                } label: {
                    Label("Clear All", systemImage: "trash")
                }
                .disabled(state.newWorkIDs.isEmpty)
            })
        )
        .onAppear {
            guard !didResetPins else { return }
            didResetPins = true
            lists.resetWhatsNewPins()
        }
        .confirmationDialog("Clear What’s New?", isPresented: $confirmClear,
                            titleVisibility: .visible) {
            Button("Clear All", role: .destructive) { state.clearNewWorks() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Every entry is removed. The works stay in your library.")
        }
    }
}

// MARK: - Bookmarks

private struct BookmarksScreen: View {
    @Environment(AppState.self) private var state

    @State private var isImporting = false
    @State private var isSyncingAll = false

    var body: some View {
        WorkListScreen(
            section: .bookmarks,
            title: "Bookmarks",
            rawWorks: { state.bookmarkedWorkIDs.compactMap { state.work(byID: $0) }
                .sorted { $0.title < $1.title } },
            empty: .init(systemImage: "bookmark", title: "No bookmarks yet",
                         subtitle: "Works you bookmark will appear here."),
            menuItems: state.ao3Username == nil ? nil : AnyView(Group {
                Button {
                    Task {
                        isImporting = true
                        await state.importAO3Bookmarks()
                        isImporting = false
                    }
                } label: {
                    Label("Import from AO3", systemImage: "arrow.down.circle")
                }
                .disabled(isImporting || isSyncingAll)
                Button {
                    Task {
                        isSyncingAll = true
                        await state.pushAllSyncedBookmarks()
                        isSyncingAll = false
                    }
                } label: {
                    Label("Sync to AO3", systemImage: "arrow.up.circle")
                }
                .disabled(isImporting || isSyncingAll)
            })
        )
        .alert(
            "Remove Synced Bookmark?",
            isPresented: Binding(
                get: { state.pendingBookmarkRemoval != nil },
                set: { if !$0 { state.cancelBookmarkRemoval() } }
            )
        ) {
            Button("Remove Locally Only", role: .destructive) {
                if let id = state.pendingBookmarkRemoval {
                    state.bookmarkedWorkIDs.remove(id)
                    if let workId = UInt64(id) { state.bridge.removeBookmark(workId) }
                    state.pendingBookmarkRemoval = nil
                }
            }
            Button("Remove Everywhere", role: .destructive) {
                state.confirmBookmarkRemoval()
            }
            Button("Cancel", role: .cancel) {
                state.cancelBookmarkRemoval()
            }
        } message: {
            Text("This bookmark is synced to AO3. Would you like to also remove it from your AO3 account?")
        }
    }
}
