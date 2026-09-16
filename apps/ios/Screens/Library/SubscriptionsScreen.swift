import SwiftUI

/// AO3 subscriptions grouped by type. Author and series rows drill into
/// their stored works (`SubscriptionWorksScreen`); work rows open the work.
struct SubscriptionsScreen: View {
    @Environment(AppTheme.self) private var theme
    @Environment(AppState.self) private var state
    @Environment(NavigationState.self) private var nav
    @Environment(LibraryListModel.self) private var lists
    @Environment(SubscriptionWorksModel.self) private var subscriptionWorks

    var initialExpandedSections: Set<String> = ["Authors", "Works", "Series"]

    @State private var expanded: Set<String> = []
    @State private var didApplyInitial = false

    var body: some View {
        @Bindable var lists = lists
        ZStack(alignment: .top) {
            ScrollView {
                VStack(alignment: .leading, spacing: theme.rowGap) {
                    if state.ao3Username == nil {
                        EmptyStateView(systemImage: "bell", title: "Log in to view subscriptions",
                                       subtitle: "Your AO3 subscriptions will appear here.")
                            .padding(.top, 40)
                    } else {
                        lastCheckedLabel

                        if state.subscriptions.count > 8 {
                            ListFilterField(text: $lists.subscriptionListFilter, placeholder: "Filter subscriptions")
                        }

                        if state.isLoadingSubscriptions && state.subscriptions.isEmpty {
                            NetworkLoadingView(message: "Loading subscriptions...",
                                               task: state.subscriptionLoadTask, operation: "subscriptions") {
                                state.subscriptionLoadTask.cancel()
                                state.isLoadingSubscriptions = false
                            }
                        } else if let error = state.subscriptionError, state.subscriptions.isEmpty {
                            NetworkErrorView(message: error, onRetry: {
                                state.subscriptionError = nil
                                Task { await state.loadSubscriptions(force: true) }
                            })
                        } else if state.subscriptions.isEmpty {
                            EmptyStateView(systemImage: "bell.slash", title: "No subscriptions",
                                           subtitle: "Subscribe to authors, works, or series on AO3 to track updates.")
                                .padding(.top, 20)
                        } else {
                            let subs = lists.filteredSubscriptions
                            let authors = subs.filter { isAuthor($0) }
                            let works = subs.filter { $0.subType.lowercased().contains("work") }
                            let series = subs.filter { $0.subType.lowercased().contains("series") }

                            if !authors.isEmpty {
                                group(title: "Authors", icon: "person", items: authors)
                            }
                            if !works.isEmpty {
                                group(title: "Works", icon: "book", items: works)
                            }
                            if !series.isEmpty {
                                group(title: "Series", icon: "books.vertical", items: series)
                            }
                        }
                    }
                }
                .padding(.horizontal, theme.pad)
                .padding(.bottom, 32)
            }
            .contentMargins(.top, ScreenChromeMetrics.height, for: .scrollContent)

            ScreenChrome(title: "Subscriptions",
                         subtitle: state.subscriptions.isEmpty ? nil : "\(state.subscriptions.count) on AO3") {
                if state.ao3Username != nil {
                    ChromeIconButton(symbol: "arrow.clockwise", isBusy: state.isLoadingSubscriptions) {
                        state.bridge.invalidateSessionCache(key: "subscriptions")
                        Task { await state.loadSubscriptions(force: true) }
                    }
                    .disabled(state.isLoadingSubscriptions)
                    ChromeIconButton(symbol: "bell.badge", isBusy: state.isCheckingSubscriptions) {
                        Task { await state.checkSubscriptions(force: true) }
                    }
                    .disabled(state.isCheckingSubscriptions)
                }
            }
        }
        .libraryScreen()
        .onAppear {
            if !didApplyInitial {
                expanded = initialExpandedSections
                didApplyInitial = true
            }
        }
        .task(id: state.ao3Username) {
            if state.ao3Username != nil {
                await state.loadSubscriptions()
            }
        }
    }

    private func isAuthor(_ sub: USubscription) -> Bool {
        let t = sub.subType.lowercased()
        return t.contains("author") || t.contains("user")
    }

    private var lastCheckedLabel: some View {
        Group {
            if let ts = state.bridge.getLastSubscriptionCheck(), let date = DBTimestamp.date(ts) {
                Text("Last checked: \(date.formatted(.relative(presentation: .named)))")
                    .font(.custom("HankenGrotesk", size: 11).weight(.medium))
                    .foregroundStyle(theme.ink3)
            }
        }
    }

    private func group(title: String, icon: String, items: [USubscription]) -> some View {
        let isExpanded = expanded.contains(title)
        return VStack(alignment: .leading, spacing: 0) {
            Button {
                withAnimation(.easeInOut(duration: 0.2)) {
                    if isExpanded { expanded.remove(title) } else { expanded.insert(title) }
                }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: icon)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(theme.ink3)
                    Text("\(title) (\(items.count))")
                        .font(.custom("HankenGrotesk", size: 13).weight(.semibold))
                        .foregroundStyle(theme.ink2)
                    Spacer()
                    Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(theme.ink3)
                }
                .padding(.vertical, 10)
            }
            .buttonStyle(.plain)

            if isExpanded {
                LazyVStack(spacing: 0) {
                    ForEach(items, id: \.id) { sub in
                        row(sub)
                        if sub.id != items.last?.id {
                            Divider().padding(.leading, 14)
                        }
                    }
                }
                .background(theme.surface)
                .clipShape(RoundedRectangle(cornerRadius: Radius.card))
                .overlay(RoundedRectangle(cornerRadius: Radius.card).stroke(theme.line, lineWidth: 1))
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
    }

    private func row(_ sub: USubscription) -> some View {
        let lastChecked = state.subscriptionLastChecked["\(sub.subType):\(sub.id)"]
        return Button {
            open(sub)
        } label: {
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(sub.name)
                        .font(.custom("HankenGrotesk", size: 14).weight(.medium))
                        .foregroundStyle(theme.ink)
                        .lineLimit(1)
                    if let lastChecked, let rel = DBTimestamp.relative(lastChecked) {
                        Text("Checked \(rel)")
                            .font(.custom("HankenGrotesk", size: 11))
                            .foregroundStyle(theme.ink3)
                    }
                }
                Spacer()
                if subscriptionWorks.loadingSubscriptionID == sub.id {
                    ProgressView().controlSize(.small).tint(theme.ink3)
                }
                Image(systemName: "chevron.right")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(theme.ink3)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func open(_ sub: USubscription) {
        let type = sub.subType.lowercased()
        if type.contains("work") {
            if UInt64(sub.id) != nil { nav.openWork(sub.id) }
        } else {
            nav.openSubscriptionWorks(id: sub.id, name: sub.name,
                                      subType: type.contains("series") ? "series" : "author")
        }
    }
}

/// Subscriptions drill-in: one author's or series' locally stored works,
/// with the crawl age and an explicit full refresh (cancellable).
struct SubscriptionWorksScreen: View {
    @Environment(AppTheme.self) private var theme
    @Environment(AppState.self) private var state
    @Environment(LibraryListModel.self) private var lists
    @Environment(SubscriptionWorksModel.self) private var subscriptionWorks

    let id: String
    let name: String
    let subType: String

    /// Open once per screen instance: onAppear fires again when a work
    /// detail pushed on top is popped, and re-opening would cancel a crawl.
    @State private var didOpen = false

    var body: some View {
        WorkListScreen(
            section: .subscriptions,
            title: name,
            subtitle: subtitleLine,
            rawWorks: { subscriptionWorks.subId == id ? subscriptionWorks.works : [] },
            empty: .init(systemImage: subType == "series" ? "books.vertical" : "person",
                         title: "No stored works",
                         subtitle: "Refresh to fetch the complete list from AO3."),
            usesSectionPrefs: false,
            header: AnyView(header),
            menuItems: AnyView(
                Button {
                    subscriptionWorks.isLoading ? subscriptionWorks.cancelRefresh() : subscriptionWorks.refresh()
                } label: {
                    if subscriptionWorks.isLoading {
                        Label("Cancel Refresh", systemImage: "xmark.circle")
                    } else {
                        Label("Refresh from AO3", systemImage: "arrow.clockwise")
                    }
                }
            )
        )
        .onAppear {
            guard !didOpen else { return }
            didOpen = true
            if subscriptionWorks.open(subscriptionID: id, author: name, subType: subType) {
                lists.listEmptied(.subscriptions)
            }
        }
    }

    private var subtitleLine: String {
        let count = subscriptionWorks.works.count
        let stored = count == 1 ? "1 stored work" : "\(count) stored works"
        if let crawledAt = subscriptionWorks.crawledAt, !crawledAt.isEmpty,
           let rel = DBTimestamp.relative(crawledAt) {
            return "\(stored) · refreshed \(rel)"
        }
        return stored
    }

    @ViewBuilder
    private var header: some View {
        if subscriptionWorks.isLoading {
            HStack(spacing: 10) {
                ProgressView().controlSize(.small).tint(theme.ink3)
                Text(subscriptionWorks.fetchStatus ?? "Fetching works from AO3…")
                    .font(.custom("HankenGrotesk", size: 12).weight(.medium))
                    .foregroundStyle(theme.ink3)
                Spacer()
                Button("Cancel") { subscriptionWorks.cancelRefresh() }
                    .font(Typography.smallButtonLabel())
                    .foregroundStyle(theme.accent)
                    .buttonStyle(ButtonPressStyle())
            }
        } else if let error = subscriptionWorks.error {
            NetworkErrorView(message: error, onRetry: { subscriptionWorks.refresh() })
        } else if subscriptionWorks.crawledAt == nil || subscriptionWorks.crawledAt?.isEmpty == true {
            Button {
                subscriptionWorks.refresh()
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 13, weight: .semibold))
                    Text("Fetch complete works list from AO3")
                        .font(Typography.smallButtonLabel())
                    Spacer()
                }
                .foregroundStyle(theme.accent)
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .background(
                    RoundedRectangle(cornerRadius: Radius.smallButton)
                        .stroke(theme.accent, lineWidth: 1)
                )
            }
            .buttonStyle(ButtonPressStyle())
        }
    }
}
