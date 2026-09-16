import Foundation
import Observation

/// Device-local follows of fandoms and authors — a bell the user can shade
/// anywhere an author name appears, never an AO3 request. Stored in the
/// encrypted Rust DB (followed_items), mirrored here for synchronous reads.
@Observable
@MainActor
final class FollowModel {
    let appState: AppState

    init(appState: AppState) {
        self.appState = appState
    }

    /// What the list-item follow bell shows for an author. The bell is
    /// shaded for any non-none state, but its tap only ever toggles the
    /// device-local follow — AO3 subscribe/unsubscribe lives solely in the
    /// Subscriptions view and the author card.
    enum AuthorFollowState {
        case none
        /// Followed locally (possibly also subscribed) — the bell unfollows.
        case followed
        /// Subscribed on AO3 without a local follow — the bell is shaded as
        /// an indicator; tapping adds a local follow.
        case subscribedOnly

        var shaded: Bool { self != .none }
    }

    private(set) var followedFandoms: [String] = []
    private(set) var followedAuthorNames: [String] = []

    private var loaded = false

    /// Load follows from the Rust core (migrating any pre-DB UserDefaults
    /// follows into it, once). Called after the encrypted DB unlocks.
    func load() {
        guard !loaded, appState.bridge.isDatabaseOpen else { return }
        loaded = true
        migrateUserDefaultsFollows()
        followedFandoms = appState.bridge.getFollowed(kind: "fandom")
        followedAuthorNames = appState.bridge.getFollowed(kind: "author")
    }

    private func migrateUserDefaultsFollows() {
        let defaults = UserDefaults.standard
        for (defaultsKey, kind) in [("followedFandoms", "fandom"), ("followedAuthors", "author")] {
            if let names = defaults.stringArray(forKey: defaultsKey) {
                for name in names { appState.bridge.addFollowed(kind: kind, name: name) }
                defaults.removeObject(forKey: defaultsKey)
            }
        }
    }

    func followFandom(_ name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, !followedFandoms.contains(trimmed) else { return }
        followedFandoms.append(trimmed)
        appState.bridge.addFollowed(kind: "fandom", name: trimmed)
    }

    func unfollowFandom(_ name: String) {
        followedFandoms.removeAll { $0 == name }
        appState.bridge.removeFollowed(kind: "fandom", name: name)
    }

    func isFandomFollowed(_ name: String) -> Bool {
        followedFandoms.contains(name)
    }

    func followAuthor(_ name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, !followedAuthorNames.contains(trimmed) else { return }
        followedAuthorNames.append(trimmed)
        appState.bridge.addFollowed(kind: "author", name: trimmed)
    }

    func unfollowAuthor(_ name: String) {
        followedAuthorNames.removeAll { $0 == name }
        appState.bridge.removeFollowed(kind: "author", name: name)
    }

    /// Whether the author has a device-local follow. Follows are stored as
    /// the byline string, so a "Pseud (username)" byline also matches a
    /// follow saved under the bare username.
    func isAuthorFollowedLocally(_ author: String) -> Bool {
        followedAuthorNames.contains(author)
            || followedAuthorNames.contains(AppState.canonicalAuthorUsername(author))
    }

    /// The list rows' byline bell: shaded when the author is followed
    /// locally or subscribed on AO3.
    func authorFollowState(_ author: String) -> AuthorFollowState {
        if isAuthorFollowedLocally(author) { return .followed }
        if appState.isSubscribedToAuthor(author) { return .subscribedOnly }
        return .none
    }

    /// Toggle for that bell — device-local follow only, never an AO3
    /// request.
    func toggleAuthorFollow(_ author: String) {
        if followedAuthorNames.contains(author) {
            unfollowAuthor(author)
        } else if followedAuthorNames.contains(AppState.canonicalAuthorUsername(author)) {
            unfollowAuthor(AppState.canonicalAuthorUsername(author))
        } else {
            followAuthor(author)
        }
    }
}
