import SwiftUI

extension AuthorProfileView {
    // MARK: - Refresh / cancel

    func refreshOrCancelActivePane() {
        switch author.pane {
        case .works:
            if author.isLoadingWorks {
                author.cancelWorksRefresh()
                if let opID = author.worksRefreshOp.opID { state.bridge.cancelOperation(opID) }
            } else {
                author.refreshWorks()
            }
        case .bookmarks:
            if author.isLoadingBookmarks {
                if let opID = author.bookmarksRefreshOp.opID { state.bridge.cancelOperation(opID) }
            } else {
                author.refreshBookmarks()
            }
        case .collections:
            if !author.isLoadingCollections {
                author.refreshCollections()
            }
        }
    }

    /// The active pane's AO3 actions — full-list refreshes are long
    /// crawls, so they sit in this menu rather than on a one-tap button.
    var paneMenu: some View {
        Menu {
            if paneBusy {
                Button { refreshOrCancelActivePane() } label: {
                    Label("Cancel Refresh", systemImage: "xmark.circle")
                }
            } else {
                if author.pane == .works, let stop = author.worksCrawlStop {
                    Button { author.refreshWorks(resume: true) } label: {
                        Label("Resume (page \(stop.nextPage) of \(stop.totalPages))", systemImage: "arrow.clockwise")
                    }
                }
                Button { refreshOrCancelActivePane() } label: {
                    Label(refreshTitle, systemImage: "arrow.clockwise")
                }
            }
        } label: {
            Image(systemName: "ellipsis")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(theme.ink2)
                .frame(width: 36, height: 36)
        }
        .accessibilityLabel("More")
    }

    var refreshTitle: String {
        switch author.pane {
        case .works: author.worksCrawlStop == nil ? "Refresh Works from AO3" : "Refresh All Works from AO3"
        case .bookmarks: "Refresh Bookmarks from AO3"
        case .collections: "Refresh Collections from AO3"
        }
    }

    func cancelActivePane(_ opID: UInt64) {
        state.bridge.cancelOperation(opID)
        if author.pane == .works { author.cancelWorksRefresh() }
    }

    // MARK: - Profile header

    @ViewBuilder
    var profileHeader: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .center, spacing: 12) {
                avatarView

                VStack(alignment: .leading, spacing: 3) {
                    Text(profile?.username ?? username)
                        .font(Typography.browseTitle())
                        .foregroundStyle(theme.ink)
                        .lineLimit(1)

                    if let profile {
                        if !profile.joined.isEmpty {
                            Text(profile.location.isEmpty
                                 ? "Joined \(profile.joined)"
                                 : "Joined \(profile.joined) · \(profile.location)")
                                .font(Typography.uiCaption())
                                .foregroundStyle(theme.ink3)
                        }
                        if profile.pseuds.count > 1 {
                            Text("Pseuds: \(profile.pseuds.joined(separator: ", "))")
                                .font(Typography.uiCaption())
                                .foregroundStyle(theme.ink3)
                                .lineLimit(2)
                        }
                    } else if state.userProfileLoading.contains(username.lowercased()) {
                        HStack(spacing: 6) {
                            ProgressView().controlSize(.mini).tint(theme.ink3)
                            Text("Loading profile…")
                                .font(Typography.uiCaption())
                                .foregroundStyle(theme.ink3)
                        }
                    }
                }

                Spacer()

                // Followed / Subscribed — following needs no account.
                FollowBellMenu(target: .author(username), glyphSize: 16, hitSize: 36)
                if state.ao3Username != nil {
                    moderationMenu
                }
            }

            if let profile {
                statsRow(profile)

                if profile.blocked || profile.muted {
                    HStack(spacing: 6) {
                        if profile.blocked { statusBadge("Blocked") }
                        if profile.muted { statusBadge("Muted") }
                    }
                }

                let bio = ParsedContentBlock.fromJSON(profile.bioJson)
                if !bio.isEmpty {
                    ContentBlockView(blocks: bio, compact: true)
                }
            } else if let profileError = state.userProfileError(username) {
                Text("Couldn’t load profile: \(profileError)")
                    .font(Typography.uiCaption())
                    .foregroundStyle(theme.ink3)
            }

        }
        .padding(.top, 8)
        .padding(.bottom, 4)
    }

    var avatarView: some View {
        Group {
            if theme.imageAutoLoad, let avatarImage {
                Image(uiImage: avatarImage)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            } else {
                Circle()
                    .fill(theme.surface2)
                    .overlay {
                        Text(String(username.prefix(1)).uppercased())
                            .font(.custom("HankenGrotesk", size: 22).weight(.bold))
                            .foregroundStyle(theme.ink3)
                    }
            }
        }
        .frame(width: 56, height: 56)
        .clipShape(Circle())
    }

    var moderationMenu: some View {
        // Block/mute need the live state before they can flip it.
        let haveState = profile != nil
        return Menu {
            Button(profile?.blocked == true ? "Unblock \(username)" : "Block \(username)…",
                   role: profile?.blocked == true ? nil : .destructive) {
                if profile?.blocked == true {
                    state.toggleAuthorBlock(username)
                } else {
                    pendingModeration = .block
                }
            }
            .disabled(!haveState || state.isUserActionBusy("block", username))

            Button(profile?.muted == true ? "Unmute \(username)" : "Mute \(username)…",
                   role: profile?.muted == true ? nil : .destructive) {
                if profile?.muted == true {
                    state.toggleAuthorMute(username)
                } else {
                    pendingModeration = .mute
                }
            }
            .disabled(!haveState || state.isUserActionBusy("mute", username))
        } label: {
            Image(systemName: "ellipsis")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(theme.ink2)
                .frame(width: 36, height: 36)
        }
    }

    func statsRow(_ profile: UUserProfile) -> some View {
        let stats: [(String, UInt32)] = [
            ("Works", profile.worksCount),
            ("Series", profile.seriesCount),
            ("Bookmarks", profile.bookmarksCount),
            ("Collections", profile.collectionsCount),
            ("Gifts", profile.giftsCount),
        ]
        return Text(stats.map { "\($0.0) \($0.1)" }.joined(separator: " · "))
            .font(Typography.uiCaption())
            .foregroundStyle(theme.ink2)
    }

    func statusBadge(_ label: String) -> some View {
        Text(label)
            .font(Typography.uiSmall())
            .foregroundStyle(theme.ink2)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(Capsule().fill(theme.surface2))
    }

    var moderationTitle: String {
        switch pendingModeration {
        case .block: "Block \(username)?"
        case .mute: "Mute \(username)?"
        case nil: ""
        }
    }

    var moderationButtonLabel: String {
        switch pendingModeration {
        case .block: "Block"
        case .mute: "Mute"
        case nil: ""
        }
    }

    var moderationMessage: String {
        switch pendingModeration {
        case .block:
            "\(username) won’t be able to comment on your works or reply to your comments on AO3."
        case .mute:
            "You won’t see \(username)’s works, bookmarks, or comments while browsing AO3 signed in."
        case nil: ""
        }
    }

    func loadAvatar() async {
        guard theme.imageAutoLoad, avatarImage == nil else { return }
        if let cached = state.authorAvatars[username], let image = UIImage(data: cached) {
            avatarImage = image
            return
        }
        if let data = try? await state.bridge.fetchAuthorAvatar(username),
           let image = UIImage(data: data) {
            state.authorAvatars[username] = data
            avatarImage = image
        }
    }
}
