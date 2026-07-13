import Foundation
import Observation

/// Navigation + selection state for the three-pane reader. Pure UI state —
/// all library data, network fetching, and persistence live in the shared
/// AppState/RustBridge, exactly as on iOS.
@Observable
final class MacAppModel {
    enum Section: String, CaseIterable {
        case browse, reading, history, subscriptions, fandoms, authors,
             bookmarks, downloads, stats, search
    }

    let appState: AppState

    var section: Section = .browse
    var selectedWorkID: String?
    var readerOpen = false
    var readerChapter = 0
    var immersive = false
    var query = ""
    var activeTags: Set<String> = []
    /// Reading list shown in the list pane when a collection is selected.
    var selectedReadingListID: Int64?

    init(appState: AppState) {
        self.appState = appState
    }

    var selectedWork: Work? {
        selectedWorkID.flatMap { appState.work(byID: $0) }
    }

    var hideExplicit: Bool {
        get { appState.hideExplicit }
        set { appState.hideExplicit = newValue }
    }

    // MARK: - Intents

    func goSection(_ s: Section) {
        section = s
        selectedReadingListID = nil
        readerOpen = false
        switch s {
        case .browse:
            if appState.browseResults.isEmpty {
                Task { await appState.browseLatestWorks() }
            }
        case .subscriptions:
            Task { await appState.loadSubscriptions() }
            appState.loadNotifications()
        default:
            break
        }
    }

    func goReadingList(_ listID: Int64) {
        section = .bookmarks
        selectedReadingListID = listID
        readerOpen = false
    }

    func selectWork(_ id: String) {
        if selectedWorkID != id { selectedWorkID = id }
        if readerOpen { readerOpen = false }
        // Fill in full metadata (tags, summary, chapter titles) if the row
        // came from a listing with partial data.
        Task { await appState.fetchWorkMetadata(id) }
    }

    func openReader(_ id: String, chapter: Int) {
        selectedWorkID = id
        readerChapter = chapter
        readerOpen = true
        appState.pushHistory(id)
    }

    func closeReader() {
        readerOpen = false
        immersive = false
    }

    func submitSearch() {
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return }
        section = .search
        readerOpen = false
        Task { await appState.searchAO3Raw(keys: ["work_search[query]"], values: [q]) }
    }

    func searchTag(_ tag: String) {
        query = tag
        section = .search
        readerOpen = false
        Task { await appState.searchAO3(tag: tag) }
    }

    // MARK: - Lists

    /// Book-level completion fraction for list progress bars.
    func progress(for work: Work) -> Double {
        guard let p = appState.progressMap[work.id] else { return 0 }
        let chapters = max(1, work.totalChapters)
        return min(1, (Double(p.chapter - 1) + p.pct) / Double(chapters))
    }

    var currentlyReading: [Work] {
        appState.progressMap.keys
            .compactMap { appState.work(byID: $0) }
            .sorted { appState.history.firstIndex(of: $0.id) ?? .max < appState.history.firstIndex(of: $1.id) ?? .max }
    }

    func works(for section: Section) -> [Work] {
        let works: [Work]
        switch section {
        case .browse:
            works = appState.browseResults
        case .search:
            works = appState.searchResults
        case .reading:
            works = currentlyReading
        case .history:
            works = appState.history.compactMap { appState.work(byID: $0) }
        case .bookmarks:
            if let listID = selectedReadingListID {
                works = appState.worksInReadingList(listID)
            } else {
                works = appState.bookmarkedWorkIDs.compactMap { appState.work(byID: $0) }
                    .sorted { $0.title < $1.title }
            }
        case .downloads:
            works = appState.downloadedWorkIDs.compactMap { appState.work(byID: $0) }
                .sorted { $0.title < $1.title }
        default:
            works = []
        }
        return filtered(works)
    }

    private func filtered(_ works: [Work]) -> [Work] {
        works.filter { w in
            let passesRating = !hideExplicit || w.rating != .explicit
            let matchesTags = activeTags.allSatisfy { w.tags.contains($0) }
            return passesRating && matchesTags
        }
    }

    /// Tag chips for browse/search: most common tags among current results.
    var availableTags: [String] {
        let source = section == .search ? appState.searchResults : appState.browseResults
        var counts: [String: Int] = [:]
        for work in source {
            for tag in work.tags { counts[tag, default: 0] += 1 }
        }
        return counts.sorted { $0.value > $1.value }.prefix(10).map(\.key)
    }

    // MARK: - Derived library views

    struct FandomEntry: Identifiable {
        let name: String, count: Int
        var id: String { name }
    }

    /// Fandoms represented in the local library (cached works).
    var libraryFandoms: [FandomEntry] {
        var counts: [String: Int] = [:]
        for work in appState.cachedWorks {
            counts[work.fandom, default: 0] += 1
        }
        return counts.sorted { $0.value > $1.value }.map { FandomEntry(name: $0.key, count: $0.value) }
    }

    /// Authors the user follows (from AO3 subscriptions).
    var followedAuthors: [USubscription] {
        appState.subscriptions.filter { $0.subType.lowercased().contains("user") }
    }

    struct LocalStats {
        let wordsRead: Int, worksFinished: Int, inLibrary: Int, downloaded: Int
    }

    /// Stats computed on device from progress + cached works.
    var localStats: LocalStats {
        var wordsRead = 0
        var finished = 0
        for (id, progress) in appState.progressMap {
            guard let work = appState.work(byID: id) else { continue }
            let chapters = max(1, work.totalChapters)
            let fraction = min(1, (Double(progress.chapter - 1) + progress.pct) / Double(chapters))
            wordsRead += Int(Double(work.words) * fraction)
            if fraction >= 0.99 { finished += 1 }
        }
        return LocalStats(wordsRead: wordsRead, worksFinished: finished,
                          inLibrary: appState.cachedWorks.count,
                          downloaded: appState.downloadedWorkIDs.count)
    }
}
