import SwiftUI
import UniformTypeIdentifiers

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
        OfflineScreen()
    }
}

// MARK: - Offline

/// Works kept whole on the device: the ones downloaded from a source, and
/// the books imported from a file (the menu's Import EPUB…).
private struct OfflineScreen: View {
    @Environment(AppState.self) private var state
    @Environment(NavigationState.self) private var nav

    @State private var pickingFile = false
    @State private var isImporting = false
    @State private var importError: String?

    var body: some View {
        WorkListScreen(
            section: .downloads,
            title: "Offline",
            subtitle: isImporting ? "Importing…" : nil,
            rawWorks: { state.downloadedWorkIDs.compactMap { state.work(byID: $0) }
                .sorted { $0.title < $1.title } },
            empty: .init(systemImage: "arrow.down.circle", title: "No downloads",
                         subtitle: "Works you download or import from a file will appear here for offline reading."),
            swipe: .init(label: "Delete", systemImage: "trash") { work in
                if state.downloadedWorkIDs.contains(work.id) { state.toggleDownload(work.id) }
            },
            menuItems: AnyView(
                Button {
                    pickingFile = true
                } label: {
                    Label("Import EPUB…", systemImage: "square.and.arrow.down")
                }
                .disabled(isImporting)
            )
        )
        .fileImporter(isPresented: $pickingFile, allowedContentTypes: [.epub],
                      allowsMultipleSelection: false) { result in
            switch result {
            case .success(let urls):
                guard let url = urls.first else { return }
                Task { @MainActor in
                    isImporting = true
                    let outcome = await state.importLocalFile(url)
                    isImporting = false
                    switch outcome {
                    case .imported(let workID): nav.openWork(workID)
                    case .failed(let message): importError = message
                    }
                }
            case .failure(let error):
                importError = error.localizedDescription
            }
        }
        .alert("Couldn’t import the file", isPresented: Binding(
            get: { importError != nil }, set: { if !$0 { importError = nil } })) {
            Button("OK", role: .cancel) { importError = nil }
        } message: {
            Text(importError ?? "")
        }
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
            header: state.bulkDownload != nil ? AnyView(BulkDownloadStatusBar()) : nil,
            menuItems: AnyView(Group {
                BulkDownloadMenuItem { state.currentlyReading.map(\.id) }
                Button(role: .destructive) {
                    confirmRemoveAll = true
                } label: {
                    Label("Remove All", systemImage: "trash")
                }
            })
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
                            ? "Sign in, then follow authors, works or series — updates land here after a check."
                            : "Updates to the authors, works and series you follow land here after a check."),
            marksNew: true,
            swipe: .init(label: "Remove", systemImage: "minus.circle") { work in
                state.removeNewWork(work.id)
            },
            onOpen: { work in
                state.markNewWorkSeen(work.id)
                nav.openWork(work.id)
            },
            header: state.isCheckingWhatsNew ? AnyView(WhatsNewCheckStatusBar()) : nil,
            menuItems: AnyView(Group {
                Button {
                    state.startWhatsNewCheck(all: false)
                } label: {
                    Label("Check What’s Due", systemImage: "arrow.clockwise")
                }
                .disabled(state.isCheckingWhatsNew || state.ao3Username == nil)
                Button {
                    state.startWhatsNewCheck(all: true)
                } label: {
                    Label("Check Everything", systemImage: "arrow.clockwise.circle")
                }
                .disabled(state.isCheckingWhatsNew || state.ao3Username == nil)
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

/// The app's own bookmarks: a flag on a work of any source. The signed-in
/// AO3 account's bookmarks are a separate screen, reached from the menu.
private struct BookmarksScreen: View {
    @Environment(AppState.self) private var state
    @Environment(NavigationState.self) private var nav

    var body: some View {
        WorkListScreen(
            section: .bookmarks,
            title: "Bookmarks",
            rawWorks: { state.bookmarkedWorkIDs.compactMap { state.work(byID: $0) }
                .sorted { $0.title < $1.title } },
            empty: .init(systemImage: "bookmark", title: "No bookmarks yet",
                         subtitle: "Works you bookmark, from any source, will appear here."),
            swipe: .init(label: "Remove", systemImage: "bookmark.slash") { work in
                if state.bookmarkedWorkIDs.contains(work.id) { state.toggleBookmark(work.id) }
            },
            menuItems: state.ao3Username == nil ? nil : AnyView(
                Button {
                    nav.openAO3Bookmarks()
                } label: {
                    Label("My AO3 Bookmarks", systemImage: "bookmark.square")
                }
            )
        )
    }
}
