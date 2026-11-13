import SwiftUI

/// The active AO3 account's own bookmarks — every record it has, on AO3
/// or not sent yet. Local-first: the list is the library's; AO3 is only
/// touched by the menu's explicit actions, the editor's sync, and Delete.
/// These are AO3 bookmarks, not the app's (Library › Bookmarks).
struct AO3BookmarksScreen: View {
    @Environment(AppTheme.self) private var theme
    @Environment(AppState.self) private var state
    @Environment(NavigationState.self) private var nav

    @State private var hits: [UBookmarkHit] = []
    @State private var isImporting = false
    @State private var isSyncingAll = false
    @State private var pendingDelete: UBookmarkHit?
    @State private var deleteError: String?

    private var busy: Bool { isImporting || isSyncingAll }

    var body: some View {
        // Re-read whenever a record changes (saved, sent, deleted, imported).
        let revision = state.ao3BookmarksRevision
        ZStack(alignment: .top) {
            List {
                if state.ao3Username == nil {
                    EmptyStateView(systemImage: "person.crop.circle.badge.questionmark",
                                   title: "Not signed in to AO3",
                                   subtitle: "Sign in to AO3 in Settings to see and edit your AO3 bookmarks.")
                        .padding(.top, 24)
                        .plainRow()
                } else if hits.isEmpty {
                    EmptyStateView(systemImage: "bookmark.square",
                                   title: isImporting ? "Fetching your AO3 bookmarks…" : "No AO3 bookmarks yet",
                                   subtitle: "Import the bookmarks on your AO3 account from the menu, "
                                       + "or add one from a work’s page.")
                        .padding(.top, 24)
                        .plainRow()
                } else {
                    ForEach(hits, id: \.targetKey) { hit in
                        row(hit)
                            .listRowInsets(EdgeInsets(top: theme.rowGap / 2, leading: theme.pad,
                                                      bottom: theme.rowGap / 2, trailing: theme.pad))
                            .listRowBackground(Color.clear)
                            .listRowSeparator(.hidden)
                    }
                }
                Color.clear.frame(height: 24).plainRow()
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .contentMargins(.top, ScreenChromeMetrics.height, for: .scrollContent)

            ScreenChrome(title: "AO3 Bookmarks", subtitle: subtitle) {
                Menu {
                    Button {
                        Task {
                            isImporting = true
                            await state.importAO3Bookmarks()
                            isImporting = false
                        }
                    } label: {
                        Label("Import from AO3", systemImage: "arrow.down.circle")
                    }
                    .disabled(busy)
                    Button {
                        Task {
                            isSyncingAll = true
                            await state.pushAllSyncedBookmarks()
                            isSyncingAll = false
                        }
                    } label: {
                        Label("Sync to AO3", systemImage: "arrow.up.circle")
                    }
                    .disabled(busy)
                } label: {
                    Image(systemName: "ellipsis")
                        .font(.system(size: 17, weight: .medium))
                        .foregroundStyle(theme.ink2)
                        .frame(width: 36, height: 36)
                }
                .disabled(state.ao3Username == nil)
            }
        }
        .libraryScreen()
        .onAppear(perform: reload)
        .onChange(of: revision) { reload() }
        .alert("Delete AO3 Bookmark?", isPresented: Binding(
            get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } })) {
            Button("Delete", role: .destructive) {
                guard let hit = pendingDelete else { return }
                pendingDelete = nil
                Task { deleteError = await state.deleteAO3Bookmark(hit.ao3Target) }
            }
            Button("Cancel", role: .cancel) { pendingDelete = nil }
        } message: {
            Text("“\(Self.title(of: pendingDelete))” is deleted from your AO3 bookmarks, on AO3 and in this app. "
                 + "It can’t be undone.")
        }
        .alert("Couldn’t delete the bookmark", isPresented: Binding(
            get: { deleteError != nil }, set: { if !$0 { deleteError = nil } })) {
            Button("OK", role: .cancel) { deleteError = nil }
        } message: {
            Text(deleteError ?? "")
        }
    }

    private var subtitle: String {
        if let status = state.bookmarkSyncTask.statusMessage, busy { return status }
        return hits.count == 1 ? "1 bookmark" : "\(hits.count) bookmarks"
    }

    private func row(_ hit: UBookmarkHit) -> some View {
        BookmarkHitCard(hit: hit)
            .swipeActions(edge: .leading, allowsFullSwipe: false) {
                Button(role: .destructive) {
                    pendingDelete = hit
                } label: {
                    Label("Delete", systemImage: "trash")
                }
            }
            .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                Button {
                    edit(hit)
                } label: {
                    Label("Edit", systemImage: "square.and.pencil")
                }
                .tint(theme.accent)
            }
    }

    private func edit(_ hit: UBookmarkHit) {
        switch hit.ao3Target {
        case .work(let id): nav.presentedSheet = .bookmarkEdit(workID: String(id))
        case .series(let id): nav.presentedSheet = .seriesBookmarkEdit(seriesID: id, name: Self.title(of: hit))
        }
    }

    private func reload() {
        let own = state.bridge.getOwnAo3Bookmarks()
        state.adoptFetchedWorks(own.compactMap(\.work).map(AppState.workFromSummary))
        hits = own
    }

    private static func title(of hit: UBookmarkHit?) -> String {
        hit?.work?.title ?? hit?.series?.name ?? "Bookmark"
    }
}

private extension View {
    /// A full-width list row with no chrome (empty states, spacers).
    func plainRow() -> some View {
        listRowInsets(EdgeInsets())
            .listRowBackground(Color.clear)
            .listRowSeparator(.hidden)
    }
}
