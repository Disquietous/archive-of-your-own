import SwiftUI

struct InboxView: View {
    @Environment(AppTheme.self) private var theme
    @Environment(AppState.self) private var state
    @Environment(NavigationState.self) private var nav
    @Environment(LibraryListModel.self) private var lists

    @State private var avatarCache: [String: UIImage] = [:]
    @State private var showFilter = false

    private var items: [InboxItem] { lists.filteredInboxMessages }

    private var filterActive: Bool {
        !lists.inboxFilterAuthor.isEmpty || !lists.inboxFilterWork.isEmpty || !lists.inboxFilterText.isEmpty
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                if items.isEmpty && filterActive {
                    VStack(spacing: 12) {
                        EmptyStateView(systemImage: "line.3.horizontal.decrease.circle",
                                       title: "Nothing matches",
                                       subtitle: "No messages on this page match the filter.")
                        Button("Clear Filter") { clearFilter() }
                            .font(Typography.smallButtonLabel())
                            .foregroundStyle(theme.accent)
                            .buttonStyle(ButtonPressStyle())
                    }
                    .padding(.top, 40)
                } else if items.isEmpty && state.isCheckingInbox {
                    NetworkLoadingView(message: "Checking inbox…", task: state.inboxCheckTask, operation: "inbox") {
                        state.inboxCheckTask.cancel()
                    }
                } else if items.isEmpty {
                    if let message = state.inboxCheckTask.statusMessage, !message.isEmpty {
                        NetworkErrorView(message: message, onRetry: {
                            Task { await state.checkInbox() }
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
                    }

                    pager
                        .padding(.horizontal, theme.pad)
                        .padding(.top, 16)
                }

                Spacer().frame(height: 32)
            }
        }
        .contentMargins(.top, ScreenChromeMetrics.height, for: .scrollContent)
        .libraryScreen()
        .overlay(alignment: .top) { topChrome }
        .sheet(isPresented: $showFilter) {
            InboxFilterSheet()
                .environment(theme)
                .environment(lists)
        }
        .task {
            // Cached pages render at once; the check only goes to AO3 for
            // messages newer than the cache.
            state.loadCachedInbox()
            await state.checkInbox()
        }
    }

    // MARK: - Pager (cached pages only; no request)

    private var pager: some View {
        HStack(spacing: 12) {
            pagerButton(symbol: "chevron.left", enabled: state.inboxPage > 1) {
                state.loadCachedInbox(page: state.inboxPage - 1)
            }
            Text("Page \(state.inboxPage)")
                .font(Typography.smallButtonLabel())
                .foregroundStyle(theme.ink2)
                .frame(maxWidth: .infinity)
            pagerButton(symbol: "chevron.right", enabled: state.inboxHasMore) {
                state.loadCachedInbox(page: state.inboxPage + 1)
            }
        }
    }

    private func pagerButton(symbol: String, enabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(enabled ? theme.ink : theme.ink3)
                .frame(width: 40, height: 40)
                .background(
                    RoundedRectangle(cornerRadius: Radius.button)
                        .stroke(theme.line, lineWidth: 1)
                )
        }
        .buttonStyle(ButtonPressStyle())
        .disabled(!enabled)
    }

    // MARK: - Top Chrome

    private var topChrome: some View {
        ScreenChrome(title: "Inbox",
                     subtitle: state.inboxUnreadCount > 0 ? "\(state.inboxUnreadCount) unread" : nil) {
            ChromeIconButton(symbol: filterActive ? "line.3.horizontal.decrease.circle.fill"
                                                   : "line.3.horizontal.decrease.circle",
                             tint: filterActive ? theme.accent : nil) {
                showFilter = true
            }
            ChromeIconButton(symbol: "arrow.clockwise", isBusy: state.isCheckingInbox) {
                Task { await state.checkInbox() }
            }
            .disabled(state.isCheckingInbox)
        }
    }

    private func clearFilter() {
        lists.inboxFilterAuthor = ""
        lists.inboxFilterWork = ""
        lists.inboxFilterText = ""
    }

    // MARK: - Inbox Item

    private func inboxItemView(_ item: InboxItem) -> some View {
        Button {
            state.selectInboxMessage(item)
            nav.openInboxThread()
        } label: {
            inboxItemBody(item)
        }
        .buttonStyle(.plain)
    }

    private func inboxItemBody(_ item: InboxItem) -> some View {
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
        .contentShape(Rectangle())
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
}

/// Inbox filter: sender, work, and message text as separate fields.
struct InboxFilterSheet: View {
    @Environment(AppTheme.self) private var theme
    @Environment(LibraryListModel.self) private var lists
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        @Bindable var lists = lists
        let anyActive = !lists.inboxFilterAuthor.isEmpty || !lists.inboxFilterWork.isEmpty
            || !lists.inboxFilterText.isEmpty
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    FilterTextField(placeholder: "From user", text: $lists.inboxFilterAuthor)
                    FilterTextField(placeholder: "Work title", text: $lists.inboxFilterWork)
                    FilterTextField(placeholder: "Message text", text: $lists.inboxFilterText)
                    FilterRetentionToggle()
                }
                .padding(theme.pad)
            }
            .background(theme.bg)
            .scrollDismissesKeyboard(.interactively)
            .navigationTitle("Filter Inbox")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Clear") {
                        lists.inboxFilterAuthor = ""
                        lists.inboxFilterWork = ""
                        lists.inboxFilterText = ""
                    }
                    .disabled(!anyActive)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .presentationDetents([.medium])
        .presentationDragIndicator(.visible)
    }
}
