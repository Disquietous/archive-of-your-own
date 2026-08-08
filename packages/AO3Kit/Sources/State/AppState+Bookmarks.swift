import SwiftUI

// MARK: - Bookmarks & AO3 bookmark sync

extension AppState {
    func toggleBookmark(_ id: String) {
        if bookmarkedWorkIDs.contains(id) {
            if let workId = UInt64(id), bridge.isBookmarkSynced(workId) {
                pendingBookmarkRemoval = id
            } else {
                bookmarkedWorkIDs.remove(id)
                if let workId = UInt64(id) { bridge.removeBookmark(workId) }
            }
        } else {
            bookmarkedWorkIDs.insert(id)
            if let workId = UInt64(id) { bridge.addBookmark(workId, syncToAo3: false) }
        }
    }

    func confirmBookmarkRemoval() {
        guard let id = pendingBookmarkRemoval else { return }
        bookmarkedWorkIDs.remove(id)
        if let workId = UInt64(id) {
            Task {
                _ = try? await bridge.deleteAo3Bookmark(workId: workId)
                await MainActor.run {
                    self.bridge.removeBookmark(workId)
                }
            }
        }
        pendingBookmarkRemoval = nil
    }

    func cancelBookmarkRemoval() {
        pendingBookmarkRemoval = nil
    }

    func importAO3Bookmarks() async {
        guard let username = ao3Username else { return }
        bookmarkSyncTask.reset()
        bookmarkSyncTask.statusMessage = "Importing bookmarks..."
        do {
            let bookmarks = try await bridge.pullBookmarks(username: username)
            let ids = Set(bookmarks.map { String($0.workId) })
            bookmarkedWorkIDs.formUnion(ids)
            let works = bridge.getAllCachedWorks()
            cachedWorks = works.map(Self.workFromSummary)
            bookmarksLoadedForAccount = username
            bookmarkSyncTask.statusMessage = "Imported \(bookmarks.count) bookmarks"
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
        } catch {
            // Silently fail for individual pushes
        }
    }

    func pushAllSyncedBookmarks() async {
        bookmarkSyncTask.reset()
        bookmarkSyncTask.statusMessage = "Checking login..."

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
        if !bookmarkSyncTask.isCancelled {
            bookmarkSyncTask.statusMessage = "Synced \(pushed) bookmarks"
        }
    }
}
