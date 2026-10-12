import Foundation

// MARK: - Derived library views shared by every platform's lists

extension AppState {
    /// Book-level completion fraction for list progress bars.
    func progress(for work: Work) -> Double {
        guard let p = progressMap[work.id] else { return 0 }
        let chapters = max(1, work.totalChapters)
        return min(1, (Double(p.chapter - 1) + p.pct) / Double(chapters))
    }

    /// Works with a saved position, most recently read first; works never
    /// stamped (read before last_read_dt existed) sink to the bottom.
    var currentlyReading: [Work] {
        progressMap.keys
            .compactMap { work(byID: $0) }
            .sorted {
                let a = lastReadMap[$0.id] ?? ""
                let b = lastReadMap[$1.id] ?? ""
                if a.isEmpty != b.isEmpty { return b.isEmpty }
                if a != b { return a > b }
                return $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending
            }
    }

    struct FandomEntry: Identifiable {
        let name: String, count: Int
        var id: String { name }
    }

    /// Fandoms represented in the local library (cached works). Each work
    /// counts under every fandom it's tagged with, so crossovers appear in
    /// both lists.
    var libraryFandoms: [FandomEntry] {
        var counts: [String: Int] = [:]
        for work in cachedWorks {
            let fandoms = work.fandoms.isEmpty ? [work.fandom] : work.fandoms
            for fandom in fandoms {
                counts[fandom, default: 0] += 1
            }
        }
        return counts.sorted { $0.value > $1.value }.map { FandomEntry(name: $0.key, count: $0.value) }
    }

    /// Library works tagged with a fandom — matched against every fandom
    /// tag on the work (crossovers count), the same tally `libraryFandoms`
    /// shows.
    func libraryWorks(inFandom tag: String) -> [Work] {
        cachedWorks.filter { $0.fandoms.contains(tag) || $0.fandom == tag }
    }

    /// The signed-in account's AO3 author subscriptions.
    var subscribedAuthors: [USubscription] {
        subscriptions.filter {
            let t = $0.subType.lowercased()
            return t.contains("user") || t.contains("author")
        }
    }

    struct LocalStats {
        let wordsRead: Int, worksFinished: Int, inLibrary: Int, downloaded: Int
    }

    /// Stats computed on device from progress + cached works.
    var localStats: LocalStats {
        var wordsRead = 0
        var finished = 0
        for (id, progress) in progressMap {
            guard let work = work(byID: id) else { continue }
            let chapters = max(1, work.totalChapters)
            let fraction = min(1, (Double(progress.chapter - 1) + progress.pct) / Double(chapters))
            wordsRead += Int(Double(work.words) * fraction)
            if fraction >= 0.99 { finished += 1 }
        }
        return LocalStats(wordsRead: wordsRead, worksFinished: finished,
                          inLibrary: cachedWorks.count,
                          downloaded: downloadedWorkIDs.count)
    }

    /// Clear the whole Currently Reading list (all saved positions,
    /// including orphaned records). Returns the ids that were cleared so a
    /// caller can unload any of them it is showing.
    @discardableResult
    func removeAllCurrentlyReading() -> [String] {
        let ids = Array(progressMap.keys)
        for id in ids { resetProgress(id) }
        return ids
    }

    // MARK: - AO3 links

    /// The 0-based chapter number an AO3 chapter link points at (links are
    /// classified by `AO3Link`). Saved chapters answer without a request;
    /// otherwise this is the one fetch opening the work costs anyway — the
    /// work page, which saves the work and every chapter with its AO3 id.
    /// nil when the fetch fails or the work has no such chapter.
    func resolveChapterLink(workID: String, chapterID: String) async -> Int? {
        guard let workId = UInt64(workID), let wanted = Int64(chapterID) else { return nil }
        func index(in chapters: [UChapter]) -> Int? {
            chapters.firstIndex { $0.chapterId == wanted }
        }
        if let chapters = fetchedChapters[workID], let i = index(in: chapters) { return i }
        let cached = bridge.getCachedChapters(workId)
        if let i = index(in: cached) {
            fetchedChapters[workID] = cached
            await fetchWorkMetadata(workID)
            return i
        }
        do {
            let summary = try await retryOnTimeout(task: metadataTask, using: bridge) {
                try await self.bridge.fetchWork(workId)
            }
            fetchedWorks[workID] = Self.workFromSummary(summary)
            let chapters = bridge.getCachedChapters(workId)
            fetchedChapters[workID] = chapters
            return index(in: chapters)
        } catch {
            return nil
        }
    }

    // MARK: - Sample data (testing/demo)

    /// Sample works use slug IDs ("baker") while real AO3 works use numeric
    /// IDs — and every bridge persistence call guards on UInt64(id), so
    /// samples exist in memory only and never touch the encrypted library.
    var sampleDataLoaded: Bool {
        fetchedWorks.keys.contains { UInt64($0) == nil }
    }

    func loadSampleData() {
        for work in MockData.works {
            fetchedWorks[work.id] = work
        }
        // Seed library state so every section has examples.
        progressMap["baker"] = ReadingProgress(chapter: 4, pos: 1180, chapterLen: 3100)
        progressMap["olive"] = ReadingProgress(chapter: 17, pos: 4930, chapterLen: 6950)
        for id in ["lamplight", "baker"] where !history.contains(id) {
            history.append(id)
        }
        bookmarkedWorkIDs.formUnion(["lamplight", "olive", "garden"])
        downloadedWorkIDs.formUnion(MockData.works.filter(\.downloaded).map(\.id))
    }

    /// Drop every sample work. Returns the ids removed so a caller can
    /// clear a selection that pointed at one.
    @discardableResult
    func clearSampleData() -> Set<String> {
        let isSample: (String) -> Bool = { UInt64($0) == nil }
        let removed = Set(fetchedWorks.keys.filter(isSample))
        fetchedWorks = fetchedWorks.filter { !isSample($0.key) }
        fetchedChapters = fetchedChapters.filter { !isSample($0.key) }
        progressMap = progressMap.filter { !isSample($0.key) }
        history.removeAll(where: isSample)
        lastReadID = history.first
        bookmarkedWorkIDs = bookmarkedWorkIDs.filter { !isSample($0) }
        downloadedWorkIDs = downloadedWorkIDs.filter { !isSample($0) }
        kudosGivenWorkIDs = kudosGivenWorkIDs.filter { !isSample($0) }
        return removed
    }

    // MARK: - Works crawl

    /// Where a stopped works crawl left off (cancelled, interrupted by the
    /// app leaving the foreground, or failed mid-way), so it can resume.
    struct CrawlStop: Equatable {
        let nextPage: UInt32
        let totalPages: UInt32

        var label: String { "Stopped at page \(nextPage) of \(totalPages)" }
    }

    /// Walk every page of a works listing on AO3 (author or series),
    /// delivering the accumulated list after each page and a human-readable
    /// progress line before each request. Works are persisted to the library
    /// by the Rust layer as they arrive. Stops early (returning what it has)
    /// if `task` is cancelled. A stopped crawl resumes with `startPage` and
    /// the works it already had as `seed`; `pageDone` reports each finished
    /// page and the listing's page count.
    func crawlAllWorks(fetchPage: @escaping (UInt32) async throws -> UPagedWorks,
                       task: NetworkTask,
                       startPage: UInt32 = 1,
                       seed: [Work] = [],
                       status: (String) -> Void,
                       partial: ([Work]) -> Void,
                       pageDone: (_ page: UInt32, _ totalPages: UInt32) -> Void = { _, _ in }) async throws -> [Work] {
        var all: [Work] = seed
        var seen = Set(seed.map(\.id))
        var page: UInt32 = max(1, startPage)
        var totalPages: UInt32 = page
        while true {
            if page == 1 {
                status("Fetching works from AO3…")
            } else {
                status("Fetching page \(page) of \(totalPages) · \(all.count) works so far…")
            }
            let result = try await retryOnTimeout(task: task, using: bridge) {
                try await fetchPage(page)
            }
            totalPages = max(result.totalPages, page)
            let works = result.works.map(AppState.workFromSummary)
            for work in works where seen.insert(work.id).inserted {
                fetchedWorks[work.id] = work
                all.append(work)
            }
            partial(all)
            pageDone(page, result.hasNextPage ? totalPages : page)
            if !result.hasNextPage || task.isCancelled { break }
            page += 1
        }
        return all
    }
}
