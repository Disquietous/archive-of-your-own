import SwiftUI

// MARK: - User profiles (block / mute) & avatars — subscribe lives in FollowModel

extension AppState {
    /// The real AO3 username behind an author string. Bylines and
    /// subscription names arrive as "Pseud (Username)" when the pseud
    /// differs — the account name is the part in parentheses. Actual AO3
    /// usernames never contain spaces or parens.
    nonisolated static func canonicalAuthorUsername(_ author: String) -> String {
        authorIdentity(author).username
    }

    /// Split an AO3 byline into its account name and pseud. Bylines render
    /// as "Pseud (Username)" — with or without the space — when the pseud
    /// differs from the account name. Profile/subscribe/block/mute are
    /// user-level (username); works lists are pseud-scoped when a pseud
    /// is present (/users/{username}/pseuds/{pseud}/works).
    nonisolated static func authorIdentity(_ author: String) -> (username: String, pseud: String?) {
        let trimmed = author.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let open = trimmed.lastIndex(of: "("), trimmed.hasSuffix(")") else {
            return (trimmed, nil)
        }
        let inner = trimmed[trimmed.index(after: open)..<trimmed.index(before: trimmed.endIndex)]
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !inner.isEmpty else { return (trimmed, nil) }
        let pseud = String(trimmed[..<open]).trimmingCharacters(in: .whitespacesAndNewlines)
        return (inner, pseud.isEmpty ? nil : pseud)
    }

    private static func profileKey(_ username: String) -> String {
        canonicalAuthorUsername(username).lowercased()
    }

    func userProfile(_ username: String) -> UUserProfile? {
        userProfiles[Self.profileKey(username)]
    }

    // MARK: - Users by row id

    func user(_ id: UInt64) -> UUser? { users[id] }
    func userError(_ id: UInt64) -> String? { userErrors[id] }
    func isLoadingUser(_ id: UInt64) -> Bool { userLoading.contains(id) }

    /// The user's source id, from the loaded record or the library row.
    func userSource(_ id: UInt64) -> String {
        if let u = users[id] { return u.source }
        if let u = bridge.getUser(id) { users[id] = u; return u.source }
        return "ao3"
    }

    /// What the user's source offers; nil only for an unknown source id.
    func userCapabilities(_ id: UInt64) -> SourceCapabilities? {
        bridge.sourceCapabilities(userSource(id))
    }

    /// Display name of the user's source ("Archive of Our Own").
    func userSourceName(_ id: UInt64) -> String {
        userCapabilities(id)?.name ?? "AO3"
    }

    /// The users row for an AO3 username (created when never seen).
    func userID(forAO3Username username: String) -> UInt64? {
        bridge.userID(forAO3Username: Self.canonicalAuthorUsername(username))
    }

    /// Load a user by id. Cache-forever: a cached copy (session or DB) is
    /// served as-is; only `forceRefresh` fetches when one exists.
    func loadUser(_ id: UInt64, forceRefresh: Bool = false) async {
        guard !userLoading.contains(id) else { return }
        userLoading.insert(id)
        defer { userLoading.remove(id) }
        if users[id]?.profileFetchedAt == nil, let cached = bridge.getUser(id) {
            users[id] = cached
        }
        if !forceRefresh, users[id]?.profileFetchedAt != nil {
            userErrors[id] = nil
            return
        }
        do {
            users[id] = try await bridge.fetchUser(id)
            userErrors[id] = nil
            // An AO3 fetch mirrors live subscription state into the
            // signed-in account's subscriptions (never follows).
            subscriptions = bridge.getPersistedSubscriptions()
        } catch {
            userErrors[id] = Self.readableError(error)
            NSLog("[user] fetch for %llu failed: %@", id, "\(error)")
        }
    }

    /// A user's avatar by row id: AO3 users through the cached avatar path
    /// (one scrape at most), any other source from the profile's URL.
    /// Failures are remembered for the session.
    func loadUserAvatar(_ id: UInt64) {
        guard userAvatars[id] == nil, !userAvatarFetches.contains(id) else { return }
        let user = users[id] ?? bridge.getUser(id)
        guard let user else { return }
        if user.source == "ao3" {
            loadAuthorAvatar(user.username, urlHint: user.avatarUrl)
            if let data = authorAvatars[user.username] { userAvatars[id] = data }
            return
        }
        guard let url = user.avatarUrl else { return }
        userAvatarFetches.insert(id)
        Task { @MainActor in
            if let data = try? await bridge.fetchImage(url: url) { userAvatars[id] = data }
        }
    }

    /// Avatar bytes for a users row, from either session cache.
    func userAvatar(_ id: UInt64) -> Data? {
        if let data = userAvatars[id] { return data }
        guard let name = users[id]?.username else { return nil }
        return authorAvatars[name]
    }

    /// Re-read a user's row after an AO3-side change (block, mute).
    private func refreshUserRow(forAO3Username username: String) {
        if let id = bridge.userID(forAO3Username: username), let u = bridge.getUser(id) {
            users[id] = u
        }
    }

    func userProfileError(_ username: String) -> String? {
        userProfileErrors[Self.profileKey(username)]
    }

    func isLoadingUserProfile(_ username: String) -> Bool {
        userProfileLoading.contains(Self.profileKey(username))
    }

    /// Whether a block/mute toggle is in flight for this user.
    /// `kind` is "block" or "mute".
    func isUserActionBusy(_ kind: String, _ username: String) -> Bool {
        userProfileToggling.contains("\(kind):\(Self.profileKey(username))")
    }

    func isSubscribedToAuthor(_ username: String) -> Bool {
        let canonical = Self.canonicalAuthorUsername(username)
        return subscriptions.contains {
            $0.subType.lowercased() == "author"
                && $0.id.caseInsensitiveCompare(canonical) == .orderedSame
        }
    }

    /// Load a user's profile. Cache-forever: a cached copy (session or DB)
    /// is served as-is and never triggers a network refresh — only an
    /// explicit `forceRefresh` (the user's manual refresh action) fetches
    /// when something is already cached. Safe to call repeatedly;
    /// concurrent loads coalesce.
    func loadUserProfile(_ username: String, forceRefresh: Bool = false) async {
        let username = Self.canonicalAuthorUsername(username)
        let key = username.lowercased()
        guard !userProfileLoading.contains(key) else { return }
        userProfileLoading.insert(key)
        defer { userProfileLoading.remove(key) }

        if userProfiles[key] == nil,
           let cached = bridge.getCachedUserProfile(username: username) {
            userProfiles[key] = cached
        }
        if !forceRefresh, userProfiles[key] != nil {
            userProfileErrors[key] = nil
            return
        }
        do {
            let fresh = try await bridge.fetchUserProfile(username: username)
            userProfiles[key] = fresh
            userProfileErrors[key] = nil
            // The fetch mirrors AO3's live subscription state into the
            // signed-in account's subscriptions (never follows) — pick that
            // up too.
            subscriptions = bridge.getPersistedSubscriptions()
        } catch {
            userProfileErrors[key] = Self.readableError(error)
            NSLog("[profile] fetch for %@ failed: %@", username, "\(error)")
        }
    }

    /// Last failure message for a block/mute action on this user, or nil
    /// when the most recent attempt succeeded.
    func userActionError(_ kind: String, _ username: String) -> String? {
        userActionErrors["\(kind):\(Self.profileKey(username))"]
    }

    func toggleAuthorBlock(_ username: String) {
        guard let me = ao3Username else { return }
        let username = Self.canonicalAuthorUsername(username)
        let key = "block:\(username.lowercased())"
        guard !userProfileToggling.contains(key) else { return }
        userProfileToggling.insert(key)
        Task { @MainActor in
            if let newState = try? await bridge.toggleUserBlock(target: username, username: me) {
                if var p = userProfiles[username.lowercased()] {
                    p.blocked = newState
                    userProfiles[username.lowercased()] = p
                }
                refreshUserRow(forAO3Username: username)
            }
            userProfileToggling.remove(key)
        }
    }

    func toggleAuthorMute(_ username: String) {
        guard let me = ao3Username else { return }
        let username = Self.canonicalAuthorUsername(username)
        let key = "mute:\(username.lowercased())"
        guard !userProfileToggling.contains(key) else { return }
        userProfileToggling.insert(key)
        Task { @MainActor in
            if let newState = try? await bridge.toggleUserMute(target: username, username: me) {
                if var p = userProfiles[username.lowercased()] {
                    p.muted = newState
                    userProfiles[username.lowercased()] = p
                }
                refreshUserRow(forAO3Username: username)
            }
            userProfileToggling.remove(key)
        }
    }

    // MARK: - Author avatars (DB-cached; fetched from AO3 at most once each)

    /// Ensure an author's avatar is available: session memory → DB cache →
    /// (once) AO3. A URL hint from inbox/comment data avoids the
    /// profile-page scrape. Failures are remembered for the session so a
    /// missing avatar never causes repeated requests.
    func loadAuthorAvatar(_ username: String, urlHint: String? = nil) {
        guard !username.isEmpty,
              authorAvatars[username] == nil,
              !avatarFetchesInFlight.contains(username),
              !avatarFailures.contains(username) else { return }
        if let cached = bridge.getCachedAuthorAvatar(username) {
            authorAvatars[username] = cached
            return
        }
        avatarFetchesInFlight.insert(username)
        Task { @MainActor in
            do {
                authorAvatars[username] = try await bridge.fetchAuthorAvatar(username, urlHint: urlHint)
            } catch {
                avatarFailures.insert(username)
            }
            avatarFetchesInFlight.remove(username)
        }
    }
}
