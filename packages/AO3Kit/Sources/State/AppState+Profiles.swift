import SwiftUI

// MARK: - User profiles (author subscribe / block / mute) & avatars

extension AppState {
    /// The real AO3 username behind an author string. Bylines and
    /// subscription names arrive as "Pseud (Username)" when the pseud
    /// differs — the account name is the part in parentheses. Actual AO3
    /// usernames never contain spaces or parens.
    static func canonicalAuthorUsername(_ author: String) -> String {
        authorIdentity(author).username
    }

    /// Split an AO3 byline into its account name and pseud. Bylines render
    /// as "Pseud (Username)" — with or without the space — when the pseud
    /// differs from the account name. Profile/subscribe/block/mute are
    /// user-level (username); works lists are pseud-scoped when a pseud
    /// is present (/users/{username}/pseuds/{pseud}/works).
    static func authorIdentity(_ author: String) -> (username: String, pseud: String?) {
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

    func userProfileError(_ username: String) -> String? {
        userProfileErrors[Self.profileKey(username)]
    }

    func isLoadingUserProfile(_ username: String) -> Bool {
        userProfileLoading.contains(Self.profileKey(username))
    }

    /// Whether a subscribe/block/mute toggle is in flight for this user.
    /// `kind` is "sub", "block", or "mute".
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
            // local table — pick that up too.
            subscriptions = bridge.getPersistedSubscriptions()
        } catch {
            userProfileErrors[key] = Self.readableError(error)
            NSLog("[profile] fetch for %@ failed: %@", username, "\(error)")
        }
    }

    func toggleAuthorSubscription(_ username: String) {
        let username = Self.canonicalAuthorUsername(username)
        let key = "sub:\(username.lowercased())"
        guard !userProfileToggling.contains(key) else { return }
        userProfileToggling.insert(key)
        Task { @MainActor in
            if let newState = try? await bridge.toggleUserSubscription(
                target: username, username: ao3Username) {
                subscriptions = bridge.getPersistedSubscriptions()
                if var p = userProfiles[username.lowercased()] {
                    p.subscribed = newState
                    userProfiles[username.lowercased()] = p
                }
            }
            userProfileToggling.remove(key)
        }
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
