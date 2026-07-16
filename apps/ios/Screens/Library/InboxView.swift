import SwiftUI

struct InboxView: View {
    @Environment(AppTheme.self) private var theme
    @Environment(AppState.self) private var state
    @Environment(NavigationState.self) private var nav
    @Environment(\.dismiss) private var dismiss

    @State private var items: [InboxItem] = []
    @State private var currentPage: UInt32 = 1
    @State private var hasNextPage = false
    @State private var isLoading = false
    @State private var loadError: String?
    @State private var inboxTask = NetworkTask()
    @State private var avatarCache: [String: UIImage] = [:]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                Spacer().frame(height: 56)

                if items.isEmpty && isLoading {
                    NetworkLoadingView(message: "Loading inbox…", task: inboxTask, operation: "inbox") {
                        inboxTask.cancel()
                        isLoading = false
                    }
                } else if items.isEmpty && !isLoading {
                    if let loadError {
                        NetworkErrorView(message: loadError, onRetry: {
                            Task { await loadPage(1, replace: true) }
                        })
                    } else {
                        EmptyStateView(
                            systemImage: "tray",
                            title: "Inbox is empty",
                            subtitle: "Comments on your works will appear here."
                        )
                        .padding(.top, 40)
                    }
                } else {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(items) { item in
                            inboxItemView(item)
                        }

                        if isLoading {
                            NetworkLoadingView(message: "Loading more…", task: inboxTask, operation: "inbox") {
                                inboxTask.cancel()
                                isLoading = false
                            }
                        }

                        if hasNextPage && !isLoading {
                            Button {
                                Task { await loadPage(currentPage + 1, replace: false) }
                            } label: {
                                Text("Load more")
                                    .font(Typography.smallButtonLabel())
                                    .foregroundStyle(theme.ink)
                                    .frame(maxWidth: .infinity)
                                    .frame(height: 40)
                                    .background(
                                        RoundedRectangle(cornerRadius: Radius.button)
                                            .stroke(theme.line, lineWidth: 1)
                                    )
                            }
                            .buttonStyle(ButtonPressStyle())
                            .padding(.horizontal, theme.pad)
                            .padding(.top, 16)
                        }
                    }
                }

                Spacer().frame(height: 32)
            }
        }
        .background(theme.bg)
        .navigationBarBackButtonHidden(true)
        .toolbar(.hidden, for: .tabBar)
        .toolbar(.hidden, for: .navigationBar)
        .overlay(alignment: .top) { topChrome }
        .task {
            await loadPage(1, replace: true)
        }
    }

    // MARK: - Top Chrome

    private var topChrome: some View {
        HStack(spacing: 10) {
            Button { dismiss() } label: {
                Image(systemName: "chevron.left")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(theme.ink)
                    .frame(width: 36, height: 36)
            }
            .buttonStyle(IconButtonPressStyle())

            Button { nav.goHome() } label: {
                Image(systemName: "house")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(theme.ink2)
                    .frame(width: 36, height: 36)
            }
            .buttonStyle(IconButtonPressStyle())

            Text("Inbox")
                .font(Typography.browseTitle())
                .foregroundStyle(theme.ink)

            Spacer()

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

    // MARK: - Inbox Item

    private func inboxItemView(_ item: InboxItem) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 10) {
                // Avatar
                avatarView(item)

                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        if !item.authorUrl.isEmpty {
                            Text(item.author)
                                .font(.custom("HankenGrotesk", size: 14).weight(.semibold))
                                .foregroundStyle(theme.accent)
                        } else {
                            Text(item.author)
                                .font(.custom("HankenGrotesk", size: 14).weight(.semibold))
                                .foregroundStyle(theme.ink)
                        }

                        if item.isUnread {
                            Circle()
                                .fill(theme.accent)
                                .frame(width: 6, height: 6)
                        }
                    }

                    Text("on \(item.workReference)")
                        .font(.custom("HankenGrotesk", size: 12).weight(.medium))
                        .foregroundStyle(theme.ink2)
                        .lineLimit(2)

                    Text(item.postedAt)
                        .font(.custom("HankenGrotesk", size: 12).weight(.medium))
                        .foregroundStyle(theme.ink3)
                }

                Spacer()
            }

            let blocks = ParsedContentBlock.fromJSON(item.contentJson)
            if !blocks.isEmpty {
                ContentBlockView(blocks: blocks, compact: true)
                    .padding(.leading, 42)
            }
        }
        .padding(.horizontal, theme.pad)
        .padding(.vertical, 12)
        .background(item.isUnread ? theme.accentSoft.opacity(0.3) : .clear)
        .overlay(alignment: .bottom) {
            Divider().foregroundStyle(theme.line)
        }
    }

    // MARK: - Avatar

    @ViewBuilder
    private func avatarView(_ item: InboxItem) -> some View {
        let size: CGFloat = 32
        if let cached = avatarCache[item.author] {
            Image(uiImage: cached)
                .resizable()
                .aspectRatio(contentMode: .fill)
                .frame(width: size, height: size)
                .clipShape(Circle())
        } else {
            Circle()
                .fill(theme.surface2)
                .frame(width: size, height: size)
                .overlay {
                    Text(String(item.author.prefix(1)).uppercased())
                        .font(.custom("HankenGrotesk", size: 14).weight(.bold))
                        .foregroundStyle(theme.ink3)
                }
                .task {
                    await loadAvatar(for: item)
                }
        }
    }

    private func loadAvatar(for item: InboxItem) async {
        guard !item.avatarUrl.isEmpty, avatarCache[item.author] == nil else { return }
        do {
            let data = try await state.bridge.fetchImage(url: item.avatarUrl)
            if let image = UIImage(data: data) {
                avatarCache[item.author] = image
            }
        } catch {}
    }

    // MARK: - Loading

    private func loadPage(_ page: UInt32, replace: Bool) async {
        guard let username = state.ao3Username else { return }
        isLoading = true
        loadError = nil
        inboxTask.reset()
        do {
            let json = try await state.retryOnTimeout(task: inboxTask, using: state.bridge) {
                try await self.state.bridge.fetchInbox(username: username, page: page)
            }
            if let data = json.data(using: .utf8),
               let response = try? JSONDecoder().decode(InboxResponse.self, from: data) {
                if replace {
                    items = response.items
                } else {
                    items.append(contentsOf: response.items)
                }
                currentPage = page
                hasNextPage = response.hasNextPage
                state.inboxUnreadCount = Int(response.unreadCount)
            }
        } catch {
            if !inboxTask.isCancelled && !"\(error)".contains("cancelled") {
                loadError = error.localizedDescription
            }
        }
        isLoading = false
    }
}
