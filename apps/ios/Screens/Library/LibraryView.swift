import SwiftUI

struct LibraryView: View {
    @Environment(AppTheme.self) private var theme
    @Environment(AppState.self) private var state
    @Environment(NavigationState.self) private var nav

    enum Tab: String, CaseIterable {
        case reading, bookmarks, subscriptions, history, downloads, lists
    }

    var initialTab: Tab = .reading
    var initialExpandedSections: Set<String> = []

    @State private var selectedTab: Tab = .reading
    @State private var didApplyInitialTab = false
    @State private var expandedSubSections: Set<String> = []

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: theme.rowGap) {
                // Masthead
                masthead

                // Segmented control
                SegmentedControlView(
                    selection: $selectedTab,
                    items: [
                        (key: Tab.reading, label: "Reading"),
                        (key: Tab.bookmarks, label: "Bookmarks"),
                        (key: Tab.subscriptions, label: "Subscriptions"),
                        (key: Tab.history, label: "History"),
                        (key: Tab.downloads, label: "Downloads"),
                        (key: Tab.lists, label: "Lists"),
                    ]
                )
                .padding(.horizontal, theme.pad)

                // Tab content
                switch selectedTab {
                case .reading:
                    readingTab
                case .bookmarks:
                    bookmarksTab
                case .subscriptions:
                    subscriptionsTab
                case .history:
                    historyTab
                case .downloads:
                    downloadsTab
                case .lists:
                    listsTab
                }
            }
            .padding(.bottom, 32)
        }
        .background { ThemeBackgroundView() }
        .onAppear {
            if !didApplyInitialTab {
                selectedTab = initialTab
                expandedSubSections = initialExpandedSections
                didApplyInitialTab = true
            }
        }
        .onChange(of: nav.goHomeRequested) { _, requested in
            if requested {
                selectedTab = .reading
                nav.goHomeRequested = false
            }
        }
    }

    // MARK: - Masthead

    private var masthead: some View {
        HStack(spacing: 10) {
            WordmarkView()

            Spacer()

            // Subscription check button
            if state.ao3Username != nil {
                Button {
                    Task { await state.checkSubscriptions() }
                } label: {
                    if state.isCheckingSubscriptions {
                        ProgressView()
                            .controlSize(.small)
                            .tint(theme.ink2)
                    } else {
                        Image(systemName: "arrow.clockwise")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(theme.ink2)
                    }
                }
                .buttonStyle(IconButtonPressStyle())
                .disabled(state.isCheckingSubscriptions)
            }

            PrivacyPillView {
                nav.presentedSheet = .privacy
            }
        }
        .padding(.horizontal, theme.pad)
        .padding(.top, 8)
    }

    private var lastCheckedLabel: some View {
        Group {
            if state.ao3Username != nil, let ts = state.bridge.getLastSubscriptionCheck(),
               let epoch = TimeInterval(ts) {
                let date = Date(timeIntervalSince1970: epoch)
                Text("Last checked: \(date.formatted(.relative(presentation: .named)))")
                    .font(.custom("HankenGrotesk", size: 11).weight(.medium))
                    .foregroundStyle(theme.ink3)
                    .padding(.horizontal, theme.pad)
            }
        }
    }

    // MARK: - Reading Tab

    @State private var showNewListDialog = false
    @State private var newListName = ""

    private var readingTab: some View {
        VStack(alignment: .leading, spacing: theme.rowGap) {
            // Last checked label
            lastCheckedLabel

            // Notifications section
            if state.unreadNotificationCount > 0 {
                notificationsSection
            }

            // Resume card
            if let resume = state.resumeWork,
               let progress = state.progressMap[resume.id] {
                let chapter = MockData.buildChapter(for: resume, index: progress.chapter - 1)
                ResumeCardView(
                    work: resume,
                    progress: progress,
                    chapter: chapter.title,
                    onTap: {
                        nav.openReader(resume.id, chapterIndex: progress.chapter - 1)
                    }
                )
                .padding(.horizontal, theme.pad)
            }

            // Reading lists
            if !state.readingLists.isEmpty || !state.shelfWorks.isEmpty {
                HStack {
                    SectionHeaderView(title: "Reading Lists")
                    Spacer()
                    Button {
                        showNewListDialog = true
                    } label: {
                        Image(systemName: "plus")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(theme.accent)
                    }
                    .buttonStyle(IconButtonPressStyle())
                }
                .padding(.horizontal, theme.pad)

                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 12) {
                        ForEach(state.readingLists, id: \.id) { list in
                            readingListCard(list)
                        }

                        newListCard
                    }
                    .padding(.horizontal, theme.pad)
                }
            }

        }
        .alert("New Reading List", isPresented: $showNewListDialog) {
            TextField("List name", text: $newListName)
            Button("Create") {
                if !newListName.trimmingCharacters(in: .whitespaces).isEmpty {
                    state.createReadingList(newListName.trimmingCharacters(in: .whitespaces))
                    newListName = ""
                }
            }
            Button("Cancel", role: .cancel) { newListName = "" }
        }
    }

    private func readingListCard(_ list: UReadingList) -> some View {
        let summary = state.readingListSummary(list.id)

        return Button {
            nav.openReadingList(list.id, name: list.name)
        } label: {
            VStack(alignment: .leading, spacing: 6) {
                Text(list.name)
                    .font(.custom("HankenGrotesk", size: 14).weight(.semibold))
                    .foregroundStyle(theme.ink)
                    .lineLimit(1)

                HStack(spacing: 8) {
                    Text("\(summary.readCount)/\(summary.totalCount) read")
                        .font(.custom("HankenGrotesk", size: 11).weight(.medium))
                        .foregroundStyle(theme.ink2)
                    Text(summary.totalWords.abbreviated + " words")
                        .font(.custom("HankenGrotesk", size: 11).weight(.medium))
                        .foregroundStyle(theme.ink3)
                }

                if !summary.topTags.isEmpty {
                    FlowLayout(spacing: 4) {
                        ForEach(summary.topTags, id: \.self) { tag in
                            Text(tag)
                                .font(.custom("HankenGrotesk", size: 10).weight(.medium))
                                .foregroundStyle(theme.ink3)
                                .lineLimit(1)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(theme.surface2)
                                .clipShape(RoundedRectangle(cornerRadius: 4))
                        }
                    }
                }
            }
            .frame(width: 170, alignment: .topLeading)
            .padding(12)
            .background(
                RoundedRectangle(cornerRadius: Radius.card)
                    .fill(theme.surface)
            )
            .overlay(
                RoundedRectangle(cornerRadius: Radius.card)
                    .stroke(theme.line, lineWidth: 1)
            )
        }
        .buttonStyle(CardPressStyle())
    }

    private var newListCard: some View {
        Button {
            showNewListDialog = true
        } label: {
            VStack(spacing: 6) {
                Image(systemName: "plus")
                    .font(.system(size: 20, weight: .medium))
                    .foregroundStyle(theme.ink3)
                Text("New list")
                    .font(Typography.uiSmall())
                    .foregroundStyle(theme.ink3)
            }
            .frame(width: 170, height: 104)
            .background(
                RoundedRectangle(cornerRadius: Radius.card)
                    .strokeBorder(theme.line, style: StrokeStyle(lineWidth: 1.5, dash: [6, 4]))
            )
        }
        .buttonStyle(CardPressStyle())
    }

    // MARK: - Notifications Section

    private var notificationsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                SectionHeaderView(title: "Updates")
                Spacer()
                Button {
                    state.markAllNotificationsRead()
                } label: {
                    Text("Mark all read")
                        .font(.custom("HankenGrotesk", size: 12).weight(.semibold))
                        .foregroundStyle(theme.accent)
                }
                .buttonStyle(ButtonPressStyle())
            }
            .padding(.horizontal, theme.pad)

            VStack(spacing: 6) {
                ForEach(state.notifications.filter { !$0.read }, id: \.id) { notif in
                    Button {
                        state.markNotificationRead(notif.id)
                        nav.openWork(String(notif.workId))
                    } label: {
                        HStack(alignment: .top, spacing: 10) {
                            Image(systemName: notificationIcon(for: notif.notifType))
                                .font(.system(size: 14, weight: .semibold))
                                .foregroundStyle(theme.accent)
                                .frame(width: 24, height: 24)

                            VStack(alignment: .leading, spacing: 3) {
                                Text(notif.title)
                                    .font(.custom("HankenGrotesk", size: 14).weight(.semibold))
                                    .foregroundStyle(theme.ink)
                                    .lineLimit(1)

                                Text(notif.author)
                                    .font(.custom("HankenGrotesk", size: 12).weight(.medium))
                                    .foregroundStyle(theme.ink2)

                                Text(notif.message)
                                    .font(.custom("HankenGrotesk", size: 12).weight(.medium))
                                    .foregroundStyle(theme.ink3)
                                    .lineLimit(2)
                            }

                            Spacer()

                            if let epoch = TimeInterval(notif.createdAt) {
                                Text(Date(timeIntervalSince1970: epoch).formatted(.relative(presentation: .named)))
                                    .font(.custom("HankenGrotesk", size: 11).weight(.medium))
                                    .foregroundStyle(theme.ink3)
                            }
                        }
                        .padding(12)
                        .background(
                            RoundedRectangle(cornerRadius: Radius.card)
                                .fill(theme.surface)
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: Radius.card)
                                .stroke(theme.accent.opacity(0.3), lineWidth: 1)
                        )
                    }
                    .buttonStyle(CardPressStyle())
                }
            }
            .padding(.horizontal, theme.pad)
        }
    }

    private func notificationIcon(for type: String) -> String {
        switch type {
        case "new_chapter": return "doc.text"
        case "new_work": return "plus.square"
        case "work_updated": return "arrow.triangle.2.circlepath"
        case "completed": return "checkmark.circle"
        default: return "bell"
        }
    }

    // MARK: - Bookmarks Tab

    @State private var isImporting = false
    @State private var isSyncingAll = false

    private var bookmarksTab: some View {
        VStack(alignment: .leading, spacing: theme.rowGap) {
            // AO3 sync buttons when logged in
            if state.ao3Username != nil {
                HStack(spacing: 10) {
                    Button {
                        Task {
                            isImporting = true
                            await state.importAO3Bookmarks()
                            isImporting = false
                        }
                    } label: {
                        HStack(spacing: 6) {
                            if isImporting {
                                ProgressView()
                                    .controlSize(.small)
                                    .tint(theme.accent)
                            } else {
                                Image(systemName: "arrow.down.circle")
                                    .font(.system(size: 13, weight: .semibold))
                            }
                            Text("Import from AO3")
                                .font(Typography.smallButtonLabel())
                        }
                        .foregroundStyle(theme.accent)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 8)
                        .background(
                            RoundedRectangle(cornerRadius: Radius.smallButton)
                                .stroke(theme.accent, lineWidth: 1)
                        )
                    }
                    .buttonStyle(ButtonPressStyle())
                    .disabled(isImporting || isSyncingAll)

                    Button {
                        Task {
                            isSyncingAll = true
                            await state.pushAllSyncedBookmarks()
                            isSyncingAll = false
                        }
                    } label: {
                        HStack(spacing: 6) {
                            if isSyncingAll {
                                ProgressView()
                                    .controlSize(.small)
                                    .tint(theme.sage)
                            } else {
                                Image(systemName: "arrow.up.circle")
                                    .font(.system(size: 13, weight: .semibold))
                            }
                            Text("Sync to AO3")
                                .font(Typography.smallButtonLabel())
                        }
                        .foregroundStyle(theme.sage)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 8)
                        .background(
                            RoundedRectangle(cornerRadius: Radius.smallButton)
                                .stroke(theme.sage, lineWidth: 1)
                        )
                    }
                    .buttonStyle(ButtonPressStyle())
                    .disabled(isImporting || isSyncingAll)

                    Spacer()
                }
                .padding(.horizontal, theme.pad)
            }

            if let statusMsg = state.bookmarkSyncTask.statusMessage {
                Text(statusMsg)
                    .font(Typography.uiSmall())
                    .foregroundStyle(theme.ink3)
                    .padding(.horizontal, theme.pad)
            }

            if state.bookmarkedWorks.isEmpty {
                EmptyStateView(
                    systemImage: "bookmark",
                    title: "No bookmarks yet",
                    subtitle: "Works you bookmark will appear here."
                )
                .padding(.top, 40)
            } else {
                LazyVStack(spacing: theme.rowGap) {
                    ForEach(state.bookmarkedWorks) { work in
                        WorkCardView(
                            work: work,
                            blurExplicit: state.hideExplicit && work.rating == .explicit,
                            onTap: { nav.openWork(work.id) }
                        )
                    }
                }
                .padding(.horizontal, theme.pad)
            }
        }
        .alert(
            "Remove Synced Bookmark?",
            isPresented: Binding(
                get: { state.pendingBookmarkRemoval != nil },
                set: { if !$0 { state.cancelBookmarkRemoval() } }
            )
        ) {
            Button("Remove Locally Only", role: .destructive) {
                if let id = state.pendingBookmarkRemoval {
                    state.bookmarkedWorkIDs.remove(id)
                    if let workId = UInt64(id) { state.bridge.removeBookmark(workId) }
                    state.pendingBookmarkRemoval = nil
                }
            }
            Button("Remove Everywhere", role: .destructive) {
                state.confirmBookmarkRemoval()
            }
            Button("Cancel", role: .cancel) {
                state.cancelBookmarkRemoval()
            }
        } message: {
            Text("This bookmark is synced to AO3. Would you like to also remove it from your AO3 account?")
        }
    }

    // MARK: - History Tab

    private var historyTab: some View {
        VStack(alignment: .leading, spacing: theme.rowGap) {
            if state.historyWorks.isEmpty {
                EmptyStateView(
                    systemImage: "clock",
                    title: "Nothing read yet",
                    subtitle: "Your reading history stays on this device, encrypted."
                )
                .padding(.top, 40)
            } else {
                // Today group
                if !todayWorks.isEmpty {
                    SectionHeaderView(title: "Today")
                        .padding(.horizontal, theme.pad)

                    LazyVStack(spacing: theme.rowGap) {
                        ForEach(todayWorks) { work in
                            WorkCardView(
                                work: work,
                                blurExplicit: state.hideExplicit && work.rating == .explicit,
                                onTap: { nav.openWork(work.id) }
                            )
                        }
                    }
                    .padding(.horizontal, theme.pad)
                }

                // Earlier this week group
                if !earlierWorks.isEmpty {
                    SectionHeaderView(title: "Earlier This Week")
                        .padding(.horizontal, theme.pad)

                    LazyVStack(spacing: theme.rowGap) {
                        ForEach(earlierWorks) { work in
                            WorkCardView(
                                work: work,
                                blurExplicit: state.hideExplicit && work.rating == .explicit,
                                onTap: { nav.openWork(work.id) }
                            )
                        }
                    }
                    .padding(.horizontal, theme.pad)
                }

                // Clear history button
                Button {
                    state.history.removeAll()
                } label: {
                    Text("Clear history")
                        .font(Typography.smallButtonLabel())
                        .foregroundStyle(theme.ink2)
                        .padding(.horizontal, 20)
                        .padding(.vertical, 10)
                        .background(
                            RoundedRectangle(cornerRadius: Radius.button)
                                .stroke(theme.line, lineWidth: 1)
                        )
                }
                .buttonStyle(ButtonPressStyle())
                .frame(maxWidth: .infinity)
                .padding(.top, 8)
            }
        }
    }

    // Split history into "Today" (first item) and "Earlier" (rest) for mock purposes
    private var todayWorks: [Work] {
        Array(state.historyWorks.prefix(1))
    }

    private var earlierWorks: [Work] {
        Array(state.historyWorks.dropFirst())
    }

    // MARK: - Downloads Tab

    private var downloadsTab: some View {
        VStack(alignment: .leading, spacing: theme.rowGap) {
            if downloadedWorks.isEmpty {
                EmptyStateView(
                    systemImage: "arrow.down.circle",
                    title: "No downloads",
                    subtitle: "Works you download will appear here for offline reading."
                )
                .padding(.top, 40)
            } else {
                LazyVStack(spacing: theme.rowGap) {
                    ForEach(downloadedWorks) { work in
                        WorkCardView(
                            work: work,
                            blurExplicit: state.hideExplicit && work.rating == .explicit,
                            onTap: { nav.openWork(work.id) }
                        )
                    }
                }
                .padding(.horizontal, theme.pad)
            }
        }
    }

    private var downloadedWorks: [Work] {
        state.allKnownWorks.filter { state.downloadedWorkIDs.contains($0.id) }
    }

    // MARK: - Lists Tab

    private var listsTab: some View {
        VStack(alignment: .leading, spacing: theme.rowGap) {
            HStack {
                SectionHeaderView(title: "Reading Lists")
                Spacer()
                Button {
                    showNewListDialog = true
                } label: {
                    Image(systemName: "plus")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(theme.accent)
                }
                .buttonStyle(IconButtonPressStyle())
            }
            .padding(.horizontal, theme.pad)

            if state.readingLists.isEmpty {
                EmptyStateView(
                    systemImage: "list.bullet.rectangle",
                    title: "No reading lists",
                    subtitle: "Create a list to organize your reading."
                )
                .padding(.top, 40)
            } else {
                LazyVStack(spacing: theme.rowGap) {
                    ForEach(state.readingLists, id: \.id) { list in
                        readingListRow(list)
                    }
                }
                .padding(.horizontal, theme.pad)
            }
        }
        .alert("New Reading List", isPresented: $showNewListDialog) {
            TextField("List name", text: $newListName)
            Button("Create") {
                if !newListName.trimmingCharacters(in: .whitespaces).isEmpty {
                    state.createReadingList(newListName.trimmingCharacters(in: .whitespaces))
                    newListName = ""
                }
            }
            Button("Cancel", role: .cancel) { newListName = "" }
        }
    }

    private func readingListRow(_ list: UReadingList) -> some View {
        let summary = state.readingListSummary(list.id)

        return Button {
            nav.openReadingList(list.id, name: list.name)
        } label: {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(list.name)
                        .font(.custom("HankenGrotesk", size: 14).weight(.semibold))
                        .foregroundStyle(theme.ink)
                        .lineLimit(1)

                    HStack(spacing: 8) {
                        Text("\(summary.readCount)/\(summary.totalCount) read")
                            .font(.custom("HankenGrotesk", size: 12).weight(.medium))
                            .foregroundStyle(theme.ink2)
                        Text(summary.totalWords.abbreviated + " words")
                            .font(.custom("HankenGrotesk", size: 12).weight(.medium))
                            .foregroundStyle(theme.ink3)
                    }
                }

                Spacer()

                Image(systemName: "chevron.right")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(theme.ink3)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 14)
            .background(theme.surface)
            .clipShape(RoundedRectangle(cornerRadius: Radius.card))
            .overlay(
                RoundedRectangle(cornerRadius: Radius.card)
                    .stroke(theme.line, lineWidth: 1)
            )
        }
        .buttonStyle(CardPressStyle())
    }

    // MARK: - Subscriptions Tab

    private var subscriptionsTab: some View {
        VStack(alignment: .leading, spacing: theme.rowGap) {
            if state.ao3Username == nil {
                EmptyStateView(
                    systemImage: "bell",
                    title: "Log in to view subscriptions",
                    subtitle: "Your AO3 subscriptions will appear here."
                )
                .padding(.top, 40)
            } else {
                // Header with refresh
                HStack {
                    SectionHeaderView(title: "AO3 Subscriptions")
                    Spacer()
                    Button {
                        state.bridge.invalidateSessionCache(key: "subscriptions")
                        Task { await state.loadSubscriptions(force: true) }
                    } label: {
                        Image(systemName: "arrow.clockwise")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(theme.ink2)
                    }
                    .buttonStyle(IconButtonPressStyle())
                    .disabled(state.isLoadingSubscriptions)
                }
                .padding(.horizontal, theme.pad)

                if state.isLoadingSubscriptions && state.subscriptions.isEmpty {
                    NetworkLoadingView(message: "Loading subscriptions...", task: state.subscriptionLoadTask, operation: "subscriptions") {
                        state.subscriptionLoadTask.cancel()
                        state.isLoadingSubscriptions = false
                    }
                } else if let error = state.subscriptionError, state.subscriptions.isEmpty {
                    NetworkErrorView(message: error, onRetry: {
                        state.subscriptionError = nil
                        Task { await state.loadSubscriptions(force: true) }
                    })
                } else if state.subscriptions.isEmpty {
                    EmptyStateView(
                        systemImage: "bell.slash",
                        title: "No subscriptions",
                        subtitle: "Subscribe to authors, works, or series on AO3 to track updates."
                    )
                    .padding(.top, 20)
                } else {
                    let authors = state.subscriptions.filter { $0.subType == "author" }
                    let works = state.subscriptions.filter { $0.subType == "work" }
                    let series = state.subscriptions.filter { $0.subType == "series" }

                    if !authors.isEmpty {
                        subscriptionSection(title: "Authors", icon: "person", items: authors)
                    }
                    if !works.isEmpty {
                        subscriptionSection(title: "Works", icon: "book", items: works)
                    }
                    if !series.isEmpty {
                        subscriptionSection(title: "Series", icon: "books.vertical", items: series)
                    }
                }
            }
        }
        .task(id: state.ao3Username) {
            if state.ao3Username != nil {
                await state.loadSubscriptions()
            }
        }
    }

    private func subscriptionSection(title: String, icon: String, items: [USubscription]) -> some View {
        let isExpanded = expandedSubSections.contains(title)

        return VStack(alignment: .leading, spacing: 0) {
            Button {
                withAnimation(.easeInOut(duration: 0.2)) {
                    if isExpanded {
                        expandedSubSections.remove(title)
                    } else {
                        expandedSubSections.insert(title)
                    }
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
                .padding(.horizontal, theme.pad)
                .padding(.vertical, 10)
            }
            .buttonStyle(.plain)

            if isExpanded {
                LazyVStack(spacing: 0) {
                    ForEach(items, id: \.id) { sub in
                        Button {
                            navigateToSubscription(sub)
                        } label: {
                            HStack {
                                Text(sub.name)
                                    .font(.custom("HankenGrotesk", size: 14).weight(.medium))
                                    .foregroundStyle(theme.ink)
                                    .lineLimit(1)
                                Spacer()
                                Image(systemName: "chevron.right")
                                    .font(.system(size: 12, weight: .medium))
                                    .foregroundStyle(theme.ink3)
                            }
                            .padding(.horizontal, theme.pad)
                            .padding(.vertical, 12)
                        }
                        .buttonStyle(.plain)

                        if sub.id != items.last?.id {
                            Divider()
                                .padding(.leading, theme.pad)
                        }
                    }
                }
                .background(theme.surface)
                .clipShape(RoundedRectangle(cornerRadius: Radius.card))
                .overlay(
                    RoundedRectangle(cornerRadius: Radius.card)
                        .stroke(theme.line, lineWidth: 1)
                )
                .padding(.horizontal, theme.pad)
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
    }

    private func navigateToSubscription(_ sub: USubscription) {
        switch sub.subType {
        case "author":
            let dest = AppDestination.authorWorks(username: sub.id)
            nav.libraryPath.append(dest)
        case "work":
            if let _ = UInt64(sub.id) {
                nav.openWork(sub.id)
            }
        case "series":
            // TODO: series detail view
            break
        default:
            break
        }
    }
}

#Preview {
    LibraryView()
        .environment(AppTheme())
        .environment(AppState())
        .environment(NavigationState())
}
