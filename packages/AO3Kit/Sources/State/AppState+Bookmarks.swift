import SwiftUI

extension Notification.Name {
    /// The active account's AO3 bookmark records changed (saved, sent,
    /// deleted, imported).
    static let ao3BookmarksChanged = Notification.Name("AoYO.ao3BookmarksChanged")
}

// MARK: - App bookmarks
//
// A flag on a work of any source. Nothing here reads or writes an AO3
// bookmark.

extension AppState {
    func toggleBookmark(_ id: String) {
        guard let workId = UInt64(id) else { return }
        if bookmarkedWorkIDs.contains(id) {
            bookmarkedWorkIDs.remove(id)
            bridge.removeBookmark(workId)
        } else {
            bookmarkedWorkIDs.insert(id)
            bridge.addBookmark(workId)
        }
    }
}

// MARK: - AO3 bookmarks
//
// The active AO3 account's bookmark records, independent of the flag.

/// What an AO3 bookmark is of — a work or a series, by row id.
enum AO3BookmarkTarget: Hashable {
    case work(UInt64)
    case series(UInt64)
}

extension UBookmarkHit {
    /// The hit's target as an editor target.
    var ao3Target: AO3BookmarkTarget {
        bookmarkType == "series" ? .series(targetId) : .work(targetId)
    }
}

extension AppState {
    /// Whether the active AO3 account has a bookmark record of this work
    /// (on AO3 or not sent yet).
    func hasAO3Bookmark(_ id: String) -> Bool {
        _ = ao3BookmarksRevision
        guard let workId = UInt64(id) else { return false }
        return bridge.getBookmarkDetails(workId) != nil
    }

    /// Call after any change to the account's AO3 bookmark records.
    func ao3BookmarksChanged() {
        ao3BookmarksRevision += 1
        NotificationCenter.default.post(name: .ao3BookmarksChanged, object: nil)
    }

    /// The account's AO3 bookmark of a target; nil when it has none.
    func ao3BookmarkDetails(_ target: AO3BookmarkTarget) -> UBookmarkDetails? {
        switch target {
        case .work(let id): bridge.getBookmarkDetails(id)
        case .series(let id): bridge.getSeriesBookmarkDetails(id)
        }
    }

    /// Write the account's AO3 bookmark of a target to the library,
    /// creating the record when there is none. No request is made.
    func saveAO3Bookmark(_ target: AO3BookmarkTarget, note: String, tagString: String,
                         collectionNames: String, isPrivate: Bool, rec: Bool, sync: Bool) {
        switch target {
        case .work(let id):
            bridge.updateBookmarkDetails(id, note: note, tagString: tagString,
                                         collectionNames: collectionNames, private: isPrivate, rec: rec)
            bridge.updateBookmarkSync(id, sync: sync)
        case .series(let id):
            bridge.updateSeriesBookmarkDetails(id, note: note, tagString: tagString,
                                               collectionNames: collectionNames, private: isPrivate, rec: rec)
            bridge.updateSeriesBookmarkSync(id, sync: sync)
        }
        ao3BookmarksChanged()
    }

    /// Create or update the bookmark on AO3 from the library record.
    func pushAO3Bookmark(_ target: AO3BookmarkTarget) async throws {
        switch target {
        case .work(let id): _ = try await bridge.pushBookmark(workId: id)
        case .series(let id): _ = try await bridge.pushSeriesBookmark(seriesId: id)
        }
        ao3BookmarksChanged()
    }

    /// Delete the account's AO3 bookmark of a target: on AO3 when it is
    /// there, then the library record. Returns an error message, nil on
    /// success. The app bookmark is untouched.
    func deleteAO3Bookmark(_ target: AO3BookmarkTarget) async -> String? {
        do {
            let deleted: Bool
            switch target {
            case .work(let id): deleted = try await bridge.deleteAo3Bookmark(workId: id)
            case .series(let id): deleted = try await bridge.deleteAo3SeriesBookmark(seriesId: id)
            }
            ao3BookmarksChanged()
            return deleted ? nil : "The archive didn’t delete the bookmark."
        } catch {
            return error.isCancellation ? nil : RustBridge.errorMessage(error)
        }
    }

    /// Pull the account's whole bookmark listing from AO3 into its
    /// records. Sets no app bookmarks.
    func importAO3Bookmarks() async {
        guard let username = ao3Username else { return }
        bookmarkSyncTask.reset()
        bookmarkSyncTask.statusMessage = "Importing bookmarks..."
        do {
            let bookmarks = try await bridge.pullBookmarks(username: username)
            reloadCachedWorks()
            bookmarksLoadedForAccount = username
            ao3BookmarksChanged()
            bookmarkSyncTask.statusMessage = "Imported \(bookmarks.count) AO3 bookmarks"
        } catch let error as Ao3Error {
            if !bookmarkSyncTask.isCancelled {
                switch error {
                case .Network(let msg):
                    bookmarkSyncTask.statusMessage = "Import failed: \(msg)"
                default:
                    bookmarkSyncTask.statusMessage = "Import failed"
                }
            }
        } catch {
            if !bookmarkSyncTask.isCancelled {
                bookmarkSyncTask.statusMessage = "Import failed"
            }
        }
    }

    func pushBookmarkToAO3(_ id: String) async {
        guard let workId = UInt64(id) else { return }
        do {
            _ = try await bridge.pushBookmark(workId: workId)
            ao3BookmarksChanged()
        } catch {
            // Silently fail for individual pushes
        }
    }

    func pushAllSyncedBookmarks() async {
        bookmarkSyncTask.reset()
        bookmarkSyncTask.statusMessage = "Syncing bookmarks..."
        let syncedIds = bridge.getSyncedBookmarkIds()
        var pushed = 0
        for workId in syncedIds {
            if bookmarkSyncTask.isCancelled { break }
            do {
                _ = try await bridge.pushBookmark(workId: workId)
                pushed += 1
            } catch {
                continue
            }
        }
        ao3BookmarksChanged()
        if !bookmarkSyncTask.isCancelled {
            bookmarkSyncTask.statusMessage = "Synced \(pushed) bookmarks"
        }
    }
}
