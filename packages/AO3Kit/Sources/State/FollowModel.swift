import Foundation
import Observation

/// Follows — the What's New check's only input — and the bell menu that
/// couples them to AO3 subscriptions. Follows are library data (encrypted
/// Rust DB, `follows` table), mirrored here for synchronous reads.
///
/// Every author, work and series bell opens a two-item menu: Followed and
/// Subscribed. Following is local and silent. Anything that touches AO3
/// goes through a confirmation (`confirmation(for:…)`) whose wording names
/// both effects, then `apply(_:)`. Subscribed implies Followed: nothing the
/// app subscribes to exists without a follow. Fandom bells stay a plain
/// local toggle — AO3 has no fandom subscriptions.
@Observable
@MainActor
final class FollowModel {
    let appState: AppState

    init(appState: AppState) {
        self.appState = appState
    }

    enum Kind: String, CaseIterable {
        case author, work, series, fandom

        /// AO3 can subscribe to this kind.
        var isSubscribable: Bool { self != .fandom }
    }

    /// A bell's target: what it follows, keyed the way the core keys it.
    struct Target: Hashable {
        let kind: Kind
        /// author/work/series: the library row id (users, works, series —
        /// what `Work.authorIDs`, `Work.id` and `SeriesInfo.seriesID`
        /// hold); fandom: tag name. Never a display name: two people with
        /// one name at two sources are two targets.
        let id: String
        /// Display name — byline, work title, series name, fandom.
        let name: String

        init(kind: Kind, id: String, name: String? = nil) {
            self.kind = kind
            let trimmed = id.trimmingCharacters(in: .whitespacesAndNewlines)
            self.id = trimmed
            let display = (name ?? trimmed).trimmingCharacters(in: .whitespacesAndNewlines)
            self.name = display.isEmpty ? self.id : display
        }

        /// An author bell for a users row.
        static func author(id: UInt64, name: String) -> Target {
            Target(kind: .author, id: String(id), name: name)
        }

        /// The author bell target for a work: its first linked author's
        /// users row. nil for a work the library has not linked yet.
        static func author(for work: Work) -> Target? {
            guard let id = work.authorIDs.first, id != 0 else { return nil }
            return .author(id: id, name: work.author)
        }

        /// The users row behind an author target.
        var userID: UInt64? { kind == .author ? UInt64(id) : nil }

        var key: String { "\(kind.rawValue):\(id.lowercased())" }
    }

    /// The author target for an AO3 byline ("Pseud (user)" or a bare
    /// username) — the surfaces that only know a name: subscriptions,
    /// pasted links, bookmark bylines, collection maintainers. `ensure`
    /// creates the users row when the library has never seen the name
    /// (a click); a render pass passes false and gets nil for an unknown
    /// name, so drawing a bell never writes a row.
    func ao3AuthorTarget(_ byline: String, ensure: Bool) -> Target? {
        let id = ensure
            ? appState.userID(forAO3Username: byline)
            : appState.bridge.lookupAO3UserID(byline)
        return id.map { Target.author(id: $0, name: byline) }
    }

    /// The account name behind an author target at a source that keeps
    /// subscriptions (the AO3-keyed subscription records); nil for a user
    /// at a source without them.
    func subscriptionName(of target: Target) -> String? {
        guard let id = target.userID else { return nil }
        let user = appState.user(id) ?? appState.bridge.getUser(id)
        guard let user, appState.bridge.sourceCapabilities(user.source)?.subscriptions == true else { return nil }
        return user.username
    }

    struct BellState: Equatable {
        var followed: Bool
        var subscribed: Bool
    }

    // MARK: - Loaded follows

    private(set) var follows: [UFollow] = []
    private var followKeys: Set<String> = []
    private var loaded = false

    var followedFandoms: [String] { follows(of: .fandom).map(\.targetId) }

    func follows(of kind: Kind) -> [UFollow] {
        follows.filter { $0.kind == kind.rawValue }
    }

    /// Load follows from the Rust core (migrating any pre-DB UserDefaults
    /// follows into it, once). Called after the encrypted DB unlocks.
    func load() {
        guard !loaded, appState.bridge.isDatabaseOpen else { return }
        loaded = true
        migrateUserDefaultsFollows()
        reload()
    }

    /// Re-read follows from the core (after a library replacement, a bulk
    /// follow, or any change made outside this model).
    func reload() {
        follows = appState.bridge.getFollows()
        followKeys = Set(follows.map { "\($0.kind):\($0.targetId.lowercased())" })
        appState.loadFollowLastChecked()
    }

    private func migrateUserDefaultsFollows() {
        let defaults = UserDefaults.standard
        for (defaultsKey, kind) in [("followedFandoms", Kind.fandom), ("followedAuthors", Kind.author)] {
            if let names = defaults.stringArray(forKey: defaultsKey) {
                for name in names {
                    let target = Target(kind: kind, id: name, name: name)
                    appState.bridge.addFollow(kind: kind.rawValue, targetId: target.id, name: target.name)
                }
                defaults.removeObject(forKey: defaultsKey)
            }
        }
    }

    // MARK: - State

    func isFollowed(_ target: Target) -> Bool {
        followKeys.contains(target.key)
    }

    /// The signed-in account's AO3 subscription (false when signed out).
    func isSubscribed(_ target: Target) -> Bool {
        guard target.kind.isSubscribable else { return false }
        // Subscriptions are AO3 records keyed by AO3 id: the username for
        // authors, the row id (AO3 number for AO3 rows) for works/series.
        let subID: String
        if target.kind == .author {
            guard let name = subscriptionName(of: target) else { return false }
            subID = name
        } else {
            subID = target.id
        }
        return appState.subscriptions.contains {
            $0.subType.lowercased() == target.kind.rawValue
                && $0.id.caseInsensitiveCompare(subID) == .orderedSame
        }
    }

    /// Whether this target's source keeps subscriptions at all (for
    /// authors, the user's source; works and series answer by their
    /// controls).
    func isSubscribableTarget(_ target: Target) -> Bool {
        target.kind == .author ? subscriptionName(of: target) != nil : true
    }

    /// The subscribe control's gate for a target, from the row's source
    /// (design/source-controls-plan.md). Series rows carry no source over
    /// the bridge yet, so they follow the active account.
    func subscribeGate(_ target: Target) -> Gate {
        switch target.kind {
        case .author:
            return target.userID.flatMap { appState.bridge.userControls($0)?.subscribe } ?? .hidden
        case .work:
            return UInt64(target.id).flatMap { appState.bridge.workControls($0)?.subscribe } ?? .hidden
        case .series:
            return appState.ao3Username != nil ? .enabled : .disabled(reason: "Sign in to subscribe")
        case .fandom:
            return .hidden
        }
    }

    /// Why Subscribed is unavailable right now, for the menu; nil when it
    /// is available or the target has no such control.
    func subscribeHint(_ target: Target) -> String? {
        if case .disabled(let reason) = subscribeGate(target) { return reason }
        return nil
    }

    func state(_ target: Target) -> BellState {
        BellState(followed: isFollowed(target), subscribed: isSubscribed(target))
    }

    /// The bell is filled when followed; a subscribed-but-unfollowed target
    /// (picked up from AO3) keeps the shaded look it always had.
    func isShaded(_ target: Target) -> Bool {
        let s = state(target)
        return s.followed || s.subscribed
    }

    /// The Subscribed item is available: the target's source keeps
    /// subscriptions and its account is signed in.
    func canSubscribe(_ target: Target) -> Bool {
        target.kind.isSubscribable && isSubscribableTarget(target) && subscribeGate(target) == .enabled
    }

    /// When this follow's own What's New check last ran.
    func lastChecked(_ target: Target) -> String? {
        appState.followLastChecked[target.key]
    }

    /// This follow's last What's New fetch was a 404 (or it's excluded
    /// from checks after too many in a row).
    func isNotFound(_ target: Target) -> Bool {
        appState.followNotFound.contains(target.key)
    }

    /// An AO3 change for this target is in flight.
    func isBusy(_ target: Target) -> Bool {
        busy.contains(target.key)
    }

    private(set) var busy: Set<String> = []

    // MARK: - Local follow (no AO3 request, no confirmation)

    func follow(_ target: Target) {
        guard !target.id.isEmpty, !isFollowed(target) else { return }
        appState.bridge.addFollow(kind: target.kind.rawValue, targetId: target.id, name: target.name)
        reload()
    }

    /// Local unfollow. Refused for a subscribed target — that goes through
    /// the confirmation (unfollowing also unsubscribes).
    func unfollow(_ target: Target) {
        guard isFollowed(target), !isSubscribed(target) else { return }
        _ = try? appState.bridge.removeFollow(kind: target.kind.rawValue, targetId: target.id)
        reload()
    }

    // Fandom conveniences (fandom bells are a plain toggle).
    func followFandom(_ name: String) { follow(Target(kind: .fandom, id: name)) }
    func unfollowFandom(_ name: String) { unfollow(Target(kind: .fandom, id: name)) }
    func isFandomFollowed(_ name: String) -> Bool { isFollowed(Target(kind: .fandom, id: name)) }

    // MARK: - Bell menu

    enum MenuItem {
        case followed, subscribed
    }

    /// One button of a confirmation. `followed`/`subscribed` is the state
    /// the target lands in when chosen.
    struct ConfirmationOption: Identifiable {
        let id = UUID()
        let label: String
        let isDestructive: Bool
        let followed: Bool
        let subscribed: Bool
    }

    /// A confirmation to show before an AO3 change. Cancel is implied —
    /// every platform adds its own.
    struct Confirmation: Identifiable {
        let id = UUID()
        let target: Target
        let title: String
        let message: String
        let options: [ConfirmationOption]
    }

    /// What toggling a menu item does. `.local` happened already (silent,
    /// no AO3 request); `.confirm` must be shown and its chosen option
    /// passed to `apply(_:to:)`.
    enum MenuOutcome {
        case local
        case confirm(Confirmation)
    }

    /// Toggle a bell-menu item. Local follow changes apply immediately; any
    /// change that touches AO3 returns the confirmation to show.
    func toggle(_ item: MenuItem, for target: Target) -> MenuOutcome {
        let s = state(target)
        switch item {
        case .followed:
            if !s.followed {
                follow(target)
                return .local
            }
            if !s.subscribed {
                unfollow(target)
                return .local
            }
            return .confirm(Confirmation(
                target: target,
                title: "Unfollow \(target.name)?",
                message: """
                    \(target.name) is also subscribed on AO3. Unfollowing unsubscribes it on AO3 too, and What’s New \
                    stops checking it. The request is sent over Tor.
                    """,
                options: [ConfirmationOption(label: "Unfollow and Unsubscribe", isDestructive: true,
                                             followed: false, subscribed: false)]))
        case .subscribed:
            let notify = notifyClause(target)
            if !s.subscribed {
                if s.followed {
                    return .confirm(Confirmation(
                        target: target,
                        title: "Subscribe to \(target.name) on AO3?",
                        message: "This changes your AO3 account: AO3 will notify you when \(notify). The request is \(appState.bridge.privacyStatus.transportPhrase).",
                        options: [ConfirmationOption(label: "Subscribe", isDestructive: false,
                                                     followed: true, subscribed: true)]))
                }
                return .confirm(Confirmation(
                    target: target,
                    title: "Subscribe to \(target.name) on AO3?",
                    message: """
                        This changes your AO3 account: AO3 will notify you when \(notify). \(target.name) will also be \
                        followed on this device, so What’s New checks it. The request is sent over Tor.
                        """,
                    options: [ConfirmationOption(label: "Subscribe and Follow", isDestructive: false,
                                                 followed: true, subscribed: true)]))
            }
            if s.followed {
                return .confirm(Confirmation(
                    target: target,
                    title: "Unsubscribe from \(target.name) on AO3?",
                    message: """
                        This changes your AO3 account: AO3 will stop notifying you about \(target.name). You can also \
                        unfollow \(target.name) on this device, so What’s New stops checking it. The request is sent \
                        over Tor.
                        """,
                    options: [
                        ConfirmationOption(label: "Unsubscribe and Unfollow", isDestructive: true,
                                           followed: false, subscribed: false),
                        ConfirmationOption(label: "Unsubscribe Only", isDestructive: false,
                                           followed: true, subscribed: false),
                    ]))
            }
            return .confirm(Confirmation(
                target: target,
                title: "Unsubscribe from \(target.name) on AO3?",
                message: "This changes your AO3 account: AO3 will stop notifying you about \(target.name). The request is \(appState.bridge.privacyStatus.transportPhrase).",
                options: [ConfirmationOption(label: "Unsubscribe", isDestructive: true,
                                             followed: false, subscribed: false)]))
        }
    }

    private func notifyClause(_ target: Target) -> String {
        switch target.kind {
        case .author: return "\(target.name) posts a new work"
        case .work, .series: return "\(target.name) updates"
        case .fandom: return "\(target.name) updates"
        }
    }

    // MARK: - Applying a confirmed change

    /// The latest outcome to show where the menu was used (both platforms
    /// show it as a transient notice). `id` changes per notice.
    struct Notice: Equatable {
        let id = UUID()
        let message: String
        let isError: Bool
    }

    private(set) var notice: Notice?

    func clearNotice() { notice = nil }

    /// Perform a confirmed option: AO3 first, then the local rows. On
    /// failure nothing local changes and the error becomes the notice.
    func apply(_ option: ConfirmationOption, to target: Target) {
        guard !busy.contains(target.key) else { return }
        busy.insert(target.key)
        Task { @MainActor in
            defer { busy.remove(target.key) }
            do {
                let change = try await appState.bridge.applyFollowChange(
                    kind: target.kind.rawValue, targetId: target.id, name: target.name,
                    followed: option.followed, subscribed: option.subscribed)
                appState.subscriptions = appState.bridge.getPersistedSubscriptions()
                appState.noteAuthorSubscription(target, subscribed: change.subscribed)
                reload()
                if let message = Self.resultMessage(change) {
                    notice = Notice(message: message, isError: false)
                }
            } catch {
                appState.subscriptions = appState.bridge.getPersistedSubscriptions()
                notice = Notice(message: "Couldn’t update AO3 subscription: \(AppState.readableError(error))",
                                isError: true)
                NSLog("[follow] change for %@ failed: %@", target.key, "\(error)")
            }
        }
    }

    static func resultMessage(_ change: UFollowChange) -> String? {
        guard change.subscriptionChanged else { return nil }
        if change.subscribed {
            return change.followAdded
                ? "Subscribed on AO3 and followed on this device."
                : "Subscribed on AO3."
        }
        if change.followRemoved { return "Unsubscribed on AO3 and unfollowed on this device." }
        if change.followed { return "Unsubscribed on AO3; still followed on this device." }
        return "Unsubscribed on AO3."
    }

    // MARK: - Bulk follow after a subscription reload

    /// Title, message and buttons for the one-time prompt after a
    /// user-initiated subscription reload finds subscriptions with no follow.
    struct BulkFollowPrompt {
        let title: String
        let message: String
        static let acceptLabel = "Follow All"
        static let declineLabel = "Not Now"
    }

    static func bulkFollowPrompt(for subscriptions: [USubscription]) -> BulkFollowPrompt {
        let n = subscriptions.count
        let noun = n == 1 ? "item" : "items"
        let names = subscriptions.prefix(3).map(\.name)
        var list = names.joined(separator: ", ")
        if n > names.count { list += ", and \(n - names.count) more" }
        let whose = n == 1 ? "1 of your AO3 subscriptions isn’t" : "\(n) of your AO3 subscriptions aren’t"
        return BulkFollowPrompt(
            title: "Follow \(n) subscribed \(noun)?",
            message: "\(whose) followed on this device, so What’s New doesn’t check \(n == 1 ? "it" : "them"): \(list). Following changes nothing on AO3.")
    }

    /// The user accepted "Follow All".
    func followAll(_ subscriptions: [USubscription]) {
        do {
            let created = try appState.bridge.followSubscriptions(subscriptions)
            reload()
            let noun = created == 1 ? "item" : "items"
            notice = Notice(message: "Followed \(created) subscribed \(noun) on this device; your AO3 subscriptions are unchanged.",
                            isError: false)
        } catch {
            notice = Notice(message: "Couldn’t follow subscriptions: \(AppState.readableError(error))", isError: true)
        }
    }
}
