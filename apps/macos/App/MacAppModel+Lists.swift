import Foundation
import Observation

extension MacAppModel {
    // MARK: - Lists

    /// A section's list: its membership (which this shell knows — pane
    /// drill-ins included) ordered and filtered by the shared list model.
    func works(for section: Section) -> [Work] {
        lists.works(for: section, raw: rawWorks(for: section))
    }

    /// Suggestion pools for the filter dialog.
    func availableTags(for s: Section) -> [String] {
        lists.availableTags(for: s, raw: rawWorks(for: s))
    }

    func availableFandoms(for s: Section) -> [String] {
        lists.availableFandoms(for: s, raw: rawWorks(for: s))
    }

    private func rawWorks(for section: Section) -> [Work] {
        switch section {
        case .search:
            appState.searchResults
        case .reading:
            appState.currentlyReading
        case .history:
            appState.history.compactMap { appState.work(byID: $0) }
        case .bookmarks:
            appState.bookmarkedWorkIDs.compactMap { appState.work(byID: $0) }
                .sorted { $0.title < $1.title }
        case .readingLists:
            selectedReadingListID.map { appState.worksInReadingList($0) } ?? []
        case .downloads:
            appState.downloadedWorkIDs.compactMap { appState.work(byID: $0) }
                .sorted { $0.title < $1.title }
        case .authorWorks:
            author.works
        case .whatsNew:
            appState.newWorkIDs.compactMap { appState.work(byID: $0) }
        // Reading-pane drill-ins: the works lists shown while these
        // sections are active (feeds availableTags + the shared filter).
        case .subscriptions:
            subscriptionWorks.works
        case .authors:
            author.works
        case .fandoms:
            fandomLibraryWorksRaw
        default:
            []
        }
    }
}
