import SwiftUI
import UIKit

/// The work-row context menu shared by every list of works — the same
/// items as the macOS `WorkRowMenuController`, minus the desktop-only
/// window and EPUB entries. Hosts append their own tail items.
struct WorkRowMenu<Tail: View>: View {
    @Environment(AppState.self) private var state
    @Environment(NavigationState.self) private var nav

    let work: Work
    /// The host's "New Reading List…" handler (it owns the name prompt).
    var onNewReadingList: ((Work) -> Void)? = nil
    /// The host's "Export as EPUB…" handler (it presents the share sheet);
    /// offered for downloaded works when set.
    var onExportEpub: ((Work) -> Void)? = nil
    @ViewBuilder var tail: () -> Tail

    private var started: Bool {
        (state.progressMap[work.id]?.chapter ?? 0) > 0
    }

    private var isReal: Bool { UInt64(work.id) != nil }

    var body: some View {
        Button {
            nav.openWork(work.id)
        } label: {
            Label("Open", systemImage: "doc.text")
        }
        Button {
            let chapter = max(0, (state.progressMap[work.id]?.chapter ?? 1) - 1)
            nav.openReader(work.id, chapterIndex: chapter)
        } label: {
            Label(started ? "Continue Reading" : "Start Reading", systemImage: "book")
        }

        Divider()

        Button {
            state.toggleBookmark(work.id)
        } label: {
            if state.bookmarkedWorkIDs.contains(work.id) {
                Label("Remove Bookmark", systemImage: "bookmark.slash")
            } else {
                Label("Bookmark", systemImage: "bookmark")
            }
        }
        if state.bookmarkedWorkIDs.contains(work.id) {
            Button {
                nav.presentedSheet = .bookmarkEdit(workID: work.id)
            } label: {
                Label("Edit Bookmark…", systemImage: "square.and.pencil")
            }
        }
        Button {
            state.toggleDownload(work.id)
        } label: {
            if state.downloadedWorkIDs.contains(work.id) {
                Label("Delete Download", systemImage: "trash")
            } else {
                Label("Download for Offline", systemImage: "arrow.down.circle")
            }
        }
        if isReal {
            Button {
                UIPasteboard.general.string = "https://archiveofourown.org/works/\(work.id)"
            } label: {
                Label("Copy AO3 Link", systemImage: "link")
            }
            if let onExportEpub, state.downloadedWorkIDs.contains(work.id) {
                Button {
                    onExportEpub(work)
                } label: {
                    Label("Export as EPUB…", systemImage: "square.and.arrow.up")
                }
            }
            readingListMenu
        }

        tail()
    }

    /// "Add to Reading List" ▸ every list with a membership checkmark
    /// (tapping toggles), plus "New Reading List…".
    private var readingListMenu: some View {
        let memberIDs = Set(UInt64(work.id).map { state.readingListIDs(forWork: $0) } ?? [])
        return Menu {
            ForEach(state.readingLists, id: \.id) { list in
                Button {
                    if memberIDs.contains(list.id) {
                        state.removeFromReadingList(list.id, workId: work.id)
                    } else {
                        state.addToReadingList(list.id, workId: work.id)
                    }
                } label: {
                    if memberIDs.contains(list.id) {
                        Label(list.name, systemImage: "checkmark")
                    } else {
                        Text(list.name)
                    }
                }
            }
            if !state.readingLists.isEmpty {
                Divider()
            }
            Button {
                onNewReadingList?(work)
            } label: {
                Label("New Reading List…", systemImage: "plus")
            }
        } label: {
            Label("Add to Reading List", systemImage: "text.badge.plus")
        }
    }
}

extension WorkRowMenu where Tail == EmptyView {
    init(work: Work, onNewReadingList: ((Work) -> Void)? = nil,
         onExportEpub: ((Work) -> Void)? = nil) {
        self.work = work
        self.onNewReadingList = onNewReadingList
        self.onExportEpub = onExportEpub
        self.tail = { EmptyView() }
    }
}
