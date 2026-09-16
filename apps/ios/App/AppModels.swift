import Foundation
import Observation

/// The iOS app's instances of the shared AO3Kit models, created once
/// alongside `AppState` and injected into the environment one by one.
/// Same composition as `MacAppModel`; the views read them via
/// `@Environment(LibraryListModel.self)` and friends.
@MainActor
@Observable
final class AppModels {
    let search: SearchModel
    let lists: LibraryListModel
    let follows: FollowModel
    let author: AuthorProfileModel
    let subscriptionWorks: SubscriptionWorksModel
    let ops: OperationsModel

    init(appState: AppState) {
        search = SearchModel()
        lists = LibraryListModel(appState: appState)
        follows = FollowModel(appState: appState)
        author = AuthorProfileModel(appState: appState)
        subscriptionWorks = SubscriptionWorksModel(appState: appState)
        ops = OperationsModel(appState: appState, search: search, author: author,
                              subscriptionWorks: subscriptionWorks)
        // A new query throws away the previous results, so the filter that
        // targeted them goes too — the same rule every other list follows.
        search.onNewQuery = { [lists, search] in
            lists.listEmptied(.search)
            if !lists.retainListFilters {
                search.bookmarkListFilter = SearchModel.BookmarkListFilter()
            }
        }
    }

    /// Load the DB-backed pieces once the encrypted store is open — call
    /// right after `AppState.loadPersistedState()`.
    func loadPersisted() {
        lists.loadPersistedPrefs()
        follows.load()
    }
}
