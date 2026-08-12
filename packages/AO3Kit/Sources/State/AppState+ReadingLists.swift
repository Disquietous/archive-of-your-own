import SwiftUI

// MARK: - Reading lists

extension AppState {
    func refreshReadingLists() {
        readingLists = bridge.getReadingLists()
    }

    @discardableResult
    func createReadingList(_ name: String) -> Int64 {
        let id = bridge.createReadingList(name)
        refreshReadingLists()
        return id
    }

    func renameReadingList(_ listId: Int64, name: String) {
        bridge.renameReadingList(listId, name: name)
        refreshReadingLists()
    }

    func deleteReadingList(_ listId: Int64) {
        bridge.deleteReadingList(listId)
        refreshReadingLists()
    }

    func addToReadingList(_ listId: Int64, workId: String) {
        guard let id = UInt64(workId) else { return }
        bridge.addToReadingList(listId, workId: id)
        refreshReadingLists()
    }

    func removeFromReadingList(_ listId: Int64, workId: String) {
        guard let id = UInt64(workId) else { return }
        bridge.removeFromReadingList(listId, workId: id)
        refreshReadingLists()
    }

    func worksInReadingList(_ listId: Int64) -> [Work] {
        let ids = bridge.getReadingListItems(listId)
        return ids.compactMap { work(byID: String($0)) }
    }

    struct ReadingListSummary {
        let totalWords: Int
        let readCount: Int
        let totalCount: Int
        let topTags: [String]
    }

    func readingListSummary(_ listId: Int64) -> ReadingListSummary {
        let works = worksInReadingList(listId)
        let totalWords = works.reduce(0) { $0 + $1.words }
        let readCount = works.filter { w in
            guard let p = progressMap[w.id] else { return false }
            // Position is a character offset now, so "finished the chapter"
            // isn't knowable here — reaching the last posted chapter is.
            return p.chapter >= max(1, w.totalChapters)
        }.count

        var tagCounts: [String: Int] = [:]
        for w in works {
            for tag in w.tags {
                tagCounts[tag, default: 0] += 1
            }
        }
        let topTags = tagCounts.sorted { $0.value > $1.value }.prefix(3).map(\.key)

        return ReadingListSummary(totalWords: totalWords, readCount: readCount, totalCount: works.count, topTags: topTags)
    }
}
