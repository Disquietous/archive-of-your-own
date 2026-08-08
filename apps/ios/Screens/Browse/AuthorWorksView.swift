import SwiftUI

struct AuthorWorksView: View {
    @Environment(AppTheme.self) private var theme
    @Environment(AppState.self) private var state
    @Environment(NavigationState.self) private var nav
    @Environment(\.dismiss) private var dismiss

    let username: String

    @State private var results: [Work] = []
    @State private var isLoading = false
    @State private var error: String?
    @State private var currentPage: UInt32 = 0
    @State private var hasMore = true
    @State private var authorTask = NetworkTask()
    @State private var avatarImage: UIImage?
    @State private var pendingModeration: ModerationAction?

    private enum ModerationAction {
        case block, mute
    }

    private var cacheKey: String { "author_works_\(username)" }

    var body: some View {
        ZStack(alignment: .top) {
            ScrollView {
                VStack(alignment: .leading, spacing: theme.rowGap) {
                    Spacer()
                        .frame(height: 56)

                    profileHeader

                    if isLoading && results.isEmpty {
                        NetworkLoadingView(message: "Loading works...", task: authorTask, operation: "author_works") {
                            authorTask.cancel()
                            isLoading = false
                        }
                    } else if let error, results.isEmpty {
                        NetworkErrorView(message: error, onRetry: {
                            Task { await loadWorks(force: true) }
                        })
                    } else {
                        LazyVStack(spacing: theme.rowGap) {
                            ForEach(results) { work in
                                WorkCardView(
                                    work: work,
                                    blurExplicit: state.hideExplicit && work.rating == .explicit,
                                    onTap: { nav.openWork(work.id) }
                                )
                            }

                            if !isLoading && hasMore {
                                Button {
                                    Task { await loadMore() }
                                } label: {
                                    Text("Load more")
                                        .font(Typography.smallButtonLabel())
                                        .foregroundStyle(theme.accent)
                                        .frame(maxWidth: .infinity)
                                        .frame(height: 44)
                                        .background(
                                            RoundedRectangle(cornerRadius: Radius.button)
                                                .stroke(theme.line, lineWidth: 1)
                                        )
                                }
                                .buttonStyle(ButtonPressStyle())
                            }

                            if isLoading && !results.isEmpty {
                                NetworkLoadingView(message: "Loading more...", task: authorTask, operation: "author_works") {
                                    authorTask.cancel()
                                }
                            }
                        }
                    }
                }
                .padding(.horizontal, theme.pad)
            }

            topChrome
        }
        .background(theme.bg)
        .navigationBarBackButtonHidden(true)
        .toolbar(.hidden, for: .tabBar)
        .toolbar(.hidden, for: .navigationBar)
        .task {
            if results.isEmpty {
                await loadWorks()
            }
        }
        .task {
            await state.loadUserProfile(username)
            await loadAvatar()
        }
        .confirmationDialog(
            moderationTitle,
            isPresented: Binding(
                get: { pendingModeration != nil },
                set: { if !$0 { pendingModeration = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button(moderationButtonLabel, role: .destructive) {
                switch pendingModeration {
                case .block: state.toggleAuthorBlock(username)
                case .mute: state.toggleAuthorMute(username)
                case nil: break
                }
                pendingModeration = nil
            }
            Button("Cancel", role: .cancel) { pendingModeration = nil }
        } message: {
            Text(moderationMessage)
        }
    }

    // MARK: - Profile header

    private var profile: UUserProfile? { state.userProfile(username) }

    @ViewBuilder
    private var profileHeader: some View {
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
                    }
                }

                Spacer()

                if state.ao3Username != nil {
                    subscribeButton
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
        .padding(.bottom, 4)
    }

    private var avatarView: some View {
        Group {
            if let avatarImage {
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

    private var subscribeButton: some View {
        let subscribed = state.isSubscribedToAuthor(username)
        let busy = state.isUserActionBusy("sub", username)
        return Button {
            state.toggleAuthorSubscription(username)
        } label: {
            Image(systemName: subscribed ? "bell.fill" : "bell")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(subscribed ? theme.accent : theme.ink2)
                .frame(width: 36, height: 36)
        }
        .buttonStyle(IconButtonPressStyle())
        .disabled(busy)
        .accessibilityLabel(subscribed ? "Unsubscribe from \(username)" : "Subscribe to \(username)")
    }

    private var moderationMenu: some View {
        Menu {
            Button(profile?.blocked == true ? "Unblock \(username)" : "Block \(username)…",
                   role: profile?.blocked == true ? nil : .destructive) {
                if profile?.blocked == true {
                    state.toggleAuthorBlock(username)
                } else {
                    pendingModeration = .block
                }
            }
            .disabled(state.isUserActionBusy("block", username))

            Button(profile?.muted == true ? "Unmute \(username)" : "Mute \(username)…",
                   role: profile?.muted == true ? nil : .destructive) {
                if profile?.muted == true {
                    state.toggleAuthorMute(username)
                } else {
                    pendingModeration = .mute
                }
            }
            .disabled(state.isUserActionBusy("mute", username))
        } label: {
            Image(systemName: "ellipsis")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(theme.ink2)
                .frame(width: 36, height: 36)
        }
    }

    private func statsRow(_ profile: UUserProfile) -> some View {
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

    private func statusBadge(_ label: String) -> some View {
        Text(label)
            .font(Typography.uiSmall())
            .foregroundStyle(theme.ink2)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(Capsule().fill(theme.surface2))
    }

    private var moderationTitle: String {
        switch pendingModeration {
        case .block: "Block \(username)?"
        case .mute: "Mute \(username)?"
        case nil: ""
        }
    }

    private var moderationButtonLabel: String {
        switch pendingModeration {
        case .block: "Block"
        case .mute: "Mute"
        case nil: ""
        }
    }

    private var moderationMessage: String {
        switch pendingModeration {
        case .block:
            "\(username) won't be able to comment on your works or reply to your comments."
        case .mute:
            "You won't see \(username)'s works, bookmarks, or comments while browsing AO3 signed in."
        case nil: ""
        }
    }

    private func loadAvatar() async {
        guard avatarImage == nil else { return }
        if let data = try? await state.bridge.fetchAuthorAvatar(username),
           let image = UIImage(data: data) {
            avatarImage = image
        }
    }

    private var topChrome: some View {
        HStack(spacing: 10) {
            Button { dismiss() } label: {
                Image(systemName: "chevron.left")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(theme.ink)
                    .frame(width: 36, height: 36)
            }
            .buttonStyle(IconButtonPressStyle())

            Text(username)
                .font(Typography.uiBody())
                .foregroundStyle(theme.ink)
                .lineLimit(1)

            Spacer()

            if !results.isEmpty {
                Button {
                    Task { await loadWorks(force: true) }
                } label: {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(theme.ink2)
                        .frame(width: 36, height: 36)
                }
                .buttonStyle(IconButtonPressStyle())
                .disabled(isLoading)
            }

            PrivacyPillView {
                nav.presentedSheet = .privacy
            }
        }
        .padding(.horizontal, theme.pad)
        .padding(.top, 8)
        .padding(.bottom, 8)
        .background(
            theme.bg.opacity(0.95)
                .shadow(.drop(color: .black.opacity(0.05), radius: 4, y: 2))
        )
    }

    private func loadWorks(force: Bool = false) async {
        guard !isLoading else { return }

        if !force, let cached = loadFromCache() {
            results = cached
            currentPage = 1
            return
        }

        isLoading = true
        error = nil
        currentPage = 0
        do {
            let result = try await state.retryOnTimeout(task: authorTask, using: state.bridge) {
                try await state.bridge.fetchAuthorWorks(username: username, page: 1)
            }
            results = result.works.map(AppState.workFromSummary)
            currentPage = 1
            hasMore = result.hasNextPage
            saveToCache(results)
        } catch {
            if !authorTask.isCancelled && !error.isCancellation {
                self.error = error.localizedDescription
            }
        }
        isLoading = false
    }

    private func loadMore() async {
        guard !isLoading else { return }
        isLoading = true
        let page = currentPage + 1
        do {
            let result = try await state.retryOnTimeout(task: authorTask, using: state.bridge) {
                try await state.bridge.fetchAuthorWorks(username: username, page: page)
            }
            let newWorks = result.works.map(AppState.workFromSummary)
            let existingIDs = Set(results.map(\.id))
            let unique = newWorks.filter { !existingIDs.contains($0.id) }
            results.append(contentsOf: unique)
            currentPage = page
            hasMore = result.hasNextPage
            saveToCache(results)
        } catch {
            if !authorTask.isCancelled && !error.isCancellation {
                self.error = error.localizedDescription
            }
        }
        isLoading = false
    }

    private func saveToCache(_ works: [Work]) {
        state.bridge.setCachedWorkList(key: cacheKey, sessionId: state.sessionId,
                                       ids: works.compactMap { UInt64($0.id) })
    }

    private func loadFromCache() -> [Work]? {
        guard let cached = state.bridge.getCachedWorkList(key: cacheKey, sessionId: state.sessionId)
        else { return nil }
        return cached.map(AppState.workFromSummary)
    }
}
