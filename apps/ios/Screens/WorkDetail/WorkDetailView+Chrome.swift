import SwiftUI

extension WorkDetailView {
    // MARK: - Chrome

    var topChrome: some View {
        ScreenChrome(title: "Details",
                     subtitle: state.isRefreshingWork ? "Refreshing from AO3…" : nil) {
            Button { state.toggleBookmark(workID) } label: {
                Image(systemName: isBookmarked ? "bookmark.fill" : "bookmark")
                    .font(.system(size: 17, weight: .medium))
                    .foregroundStyle(isBookmarked ? theme.accent : theme.ink2)
                    .frame(width: 36, height: 36)
            }
            .buttonStyle(IconButtonPressStyle())
            .simultaneousGesture(
                LongPressGesture(minimumDuration: 0.5)
                    .onEnded { _ in
                        if isBookmarked {
                            nav.presentedSheet = .bookmarkEdit(workID: workID)
                        }
                    }
            )

            if let work, isReal {
                // The work's own bell: Followed / Subscribed.
                FollowBellMenu(target: FollowModel.Target(kind: .work, id: workID, name: work.title),
                               glyphSize: 17, weight: .medium, hitSize: 36)
            }

            if work != nil {
                actionsMenu
            }
        }
    }

    /// The detail toolbar's actions, as a menu — every item the macOS
    /// detail header carries as a button.
    var actionsMenu: some View {
        Menu {
            Button {
                Task { await state.refreshWorkMetadata(workID) }
            } label: {
                Label("Refresh Details from AO3", systemImage: "arrow.clockwise")
            }
            .disabled(!isReal || state.isRefreshingWork)

            Divider()

            Button {
                nav.presentedSheet = .viewComments(workID: workID, chapterID: nil)
            } label: {
                Label(commentsLabel, systemImage: "bubble.right")
            }

            if isBookmarked {
                Button {
                    nav.presentedSheet = .bookmarkEdit(workID: workID)
                } label: {
                    Label("Edit Bookmark…", systemImage: "square.and.pencil")
                }
            }

            Button {
                nav.presentedSheet = .readingListPicker(workID: workID)
            } label: {
                Label(inReadingList ? "Reading Lists…" : "Add to Reading List…",
                      systemImage: inReadingList ? "books.vertical.fill" : "books.vertical")
            }
            .disabled(!isReal)

            Button {
                state.toggleDownload(workID)
            } label: {
                if isDownloaded {
                    Label("Delete Download", systemImage: "trash")
                } else {
                    Label("Download for Offline", systemImage: "arrow.down.circle")
                }
            }

            // Manual "done reading" flag — never set automatically.
            Button {
                state.toggleFinished(workID)
            } label: {
                Label(isFinished ? "Unmark as Finished" : "Mark as Finished",
                      systemImage: isFinished ? "checkmark.circle.fill" : "checkmark.circle")
            }

            if WorkWindowValue.isSupported, isReal {
                Button {
                    openInWindow()
                } label: {
                    Label("Open in New Window", systemImage: "macwindow.badge.plus")
                }
            }

            if let ao3URL {
                Divider()
                Button {
                    ExternalLinkOpener.open(ao3URL, bridge: state.bridge)
                } label: {
                    Label("Open on AO3", systemImage: "arrow.up.right")
                }
                ShareLink(item: ao3URL) {
                    Label("Share Link", systemImage: "square.and.arrow.up")
                }
                if isDownloaded {
                    Button {
                        exportEpub()
                    } label: {
                        Label("Export as EPUB…", systemImage: "book.closed")
                    }
                }
            }
        } label: {
            Image(systemName: "ellipsis")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(theme.ink2)
                .frame(width: 36, height: 36)
        }
    }

    var inReadingList: Bool {
        guard let workId = UInt64(workID) else { return false }
        return !state.readingListIDs(forWork: workId).isEmpty
    }

    var commentsLabel: String {
        guard let work, work.comments > 0 else { return "Comments" }
        return "Comments · \(work.comments.abbreviated)"
    }

    /// Open (or surface) this work's own window at its saved chapter.
    func openInWindow() {
        let posted = max(1, work?.chapterCount ?? 1)
        let chapter = max(0, min((progress?.chapter ?? 1) - 1, posted - 1))
        openWindow(value: WorkWindowValue(workID: workID, chapterIndex: chapter))
    }

    func exportEpub() {
        guard let work else { return }
        do {
            exportedEpub = try EpubExporter.export(work: work, appState: state)
        } catch {
            exportError = error.localizedDescription
        }
    }
}
