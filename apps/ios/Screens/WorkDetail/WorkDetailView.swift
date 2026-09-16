import SwiftUI

struct WorkDetailView: View {
    @Environment(AppTheme.self) private var theme
    @Environment(AppState.self) private var state
    @Environment(NavigationState.self) private var nav
    @Environment(FollowModel.self) private var follows
    @Environment(\.openWindow) private var openWindow

    let workID: String

    @State private var exportedEpub: EpubExporter.Exported?
    @State private var exportError: String?
    @State private var showUnsubscribeConfirm = false

    private var work: Work? {
        state.work(byID: workID)
    }

    private var progress: ReadingProgress? {
        state.progressMap[workID]
    }

    private var isBookmarked: Bool {
        state.bookmarkedWorkIDs.contains(workID)
    }

    private var isDownloaded: Bool {
        state.downloadedWorkIDs.contains(workID)
    }

    private var hasKudos: Bool {
        state.kudosGivenWorkIDs.contains(workID)
    }

    private var kudosPending: Bool {
        state.kudosPendingWorkIDs.contains(workID)
    }

    private var isReal: Bool { UInt64(workID) != nil }

    private var isLiveWork: Bool {
        isReal && work?.content == nil
    }

    private var ao3URL: URL? {
        isReal ? ExternalLinkOpener.ao3WorkURL(workID) : nil
    }

    /// The detail screen's tracked operations — refresh and kudos both post
    /// from here, so either one's requests show in the banner.
    private var bannerOpID: UInt64? {
        state.workRefreshOp.opID ?? state.kudosOp.opID
    }

    var body: some View {
        ZStack(alignment: .top) {
            if let work {
                ScrollView {
                    VStack(alignment: .leading, spacing: theme.rowGap) {
                        heroSection(work)
                        metaPills(work)
                        statsSection(work)
                        summarySection(work)
                        tagFlow(work)
                        engagementRow(work)
                        chaptersSection(work)

                        Spacer()
                            .frame(height: 90)
                    }
                    .padding(.horizontal, theme.readMargin)
                    .padding(.top, 8)
                    .padding(.bottom, 16)
                }
                .contentMargins(.top, ScreenChromeMetrics.height, for: .scrollContent)

                VStack {
                    Spacer()
                    bottomBar(work)
                }
            } else if state.metadataTask.isCancelled {
                NetworkErrorView(message: "Loading was cancelled.", onRetry: {
                    Task { await state.fetchWorkMetadata(workID) }
                })
                .frame(maxHeight: .infinity)
            } else if let error = state.searchError {
                NetworkErrorView(message: error, onRetry: {
                    Task { await state.fetchWorkMetadata(workID) }
                })
                .frame(maxHeight: .infinity)
            } else {
                NetworkLoadingView(message: "Loading work...", task: state.metadataTask) {
                    state.metadataTask.cancel()
                }
                .frame(maxHeight: .infinity)
            }

            VStack(spacing: 8) {
                topChrome
                if let opID = bannerOpID {
                    RequestProgressBanner(opID: opID) {
                        state.bridge.cancelOperation(opID)
                        state.metadataTask.cancel()
                    }
                    .padding(.horizontal, theme.pad)
                    .transition(.move(edge: .top).combined(with: .opacity))
                }
            }
            .animation(.easeInOut(duration: 0.2), value: bannerOpID)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .libraryScreen()
        .task(id: workID) {
            if isLiveWork {
                // Opening the detail view counts as "seen" for What's New.
                state.markDetailViewed(workID)
                await state.fetchWorkMetadata(workID)
            }
        }
        .sheet(item: $exportedEpub) { exported in
            ShareSheet(items: [exported.url])
        }
        .alert("Couldn’t export EPUB", isPresented: Binding(
            get: { exportError != nil }, set: { if !$0 { exportError = nil } })) {
            Button("OK") { exportError = nil }
        } message: {
            Text(exportError ?? "")
        }
        .confirmationDialog("Unsubscribe from this work on AO3?",
                            isPresented: $showUnsubscribeConfirm, titleVisibility: .visible) {
            Button("Unsubscribe", role: .destructive) {
                state.toggleWorkSubscription(workID)
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This changes your AO3 account: AO3 will stop notifying you when this work updates. The request is sent over Tor.")
        }
        .alert("Remove Synced Bookmark?", isPresented: pendingRemovalBinding) {
            Button("Remove Everywhere", role: .destructive) {
                state.confirmBookmarkRemoval()
            }
            Button("Remove Locally Only") {
                if let id = state.pendingBookmarkRemoval {
                    state.bookmarkedWorkIDs.remove(id)
                    if let workId = UInt64(id) { state.bridge.removeBookmark(workId) }
                    state.pendingBookmarkRemoval = nil
                }
            }
            Button("Cancel", role: .cancel) {
                state.cancelBookmarkRemoval()
            }
        } message: {
            Text("This bookmark is synced with your AO3 account. Remove it from AO3 as well, or only from this device?")
        }
    }

    private var pendingRemovalBinding: Binding<Bool> {
        Binding(get: { state.pendingBookmarkRemoval == workID },
                set: { if !$0 { state.cancelBookmarkRemoval() } })
    }

    // MARK: - Chrome

    private var topChrome: some View {
        ScreenChrome(title: "Details",
                     subtitle: state.isRefreshingWork ? "Refreshing from AO3…" : nil) {
            Button { state.toggleBookmark(workID) } label: {
                Image(systemName: isBookmarked ? "bookmark.fill" : "bookmark")
                    .font(.system(size: 17, weight: .medium))
                    .foregroundStyle(isBookmarked ? theme.accent : theme.ink2)
                    .frame(width: 36, height: 36)
            }
            .buttonStyle(IconButtonPressStyle())
            .simultaneousGesture(
                LongPressGesture(minimumDuration: 0.5)
                    .onEnded { _ in
                        if isBookmarked {
                            nav.presentedSheet = .bookmarkEdit(workID: workID)
                        }
                    }
            )

            if work != nil {
                actionsMenu
            }
        }
    }

    /// The detail toolbar's actions, as a menu — every item the macOS
    /// detail header carries as a button.
    private var actionsMenu: some View {
        Menu {
            Button {
                Task { await state.refreshWorkMetadata(workID) }
            } label: {
                Label("Refresh Details from AO3", systemImage: "arrow.clockwise")
            }
            .disabled(!isReal || state.isRefreshingWork)

            subscribeItem

            Divider()

            Button {
                nav.presentedSheet = .viewComments(workID: workID, chapterID: nil)
            } label: {
                Label(commentsLabel, systemImage: "bubble.right")
            }

            if isBookmarked {
                Button {
                    nav.presentedSheet = .bookmarkEdit(workID: workID)
                } label: {
                    Label("Edit Bookmark…", systemImage: "square.and.pencil")
                }
            }

            Button {
                nav.presentedSheet = .readingListPicker(workID: workID)
            } label: {
                Label(inReadingList ? "Reading Lists…" : "Add to Reading List…",
                      systemImage: inReadingList ? "books.vertical.fill" : "books.vertical")
            }
            .disabled(!isReal)

            Button {
                state.toggleDownload(workID)
            } label: {
                if isDownloaded {
                    Label("Delete Download", systemImage: "trash")
                } else {
                    Label("Download for Offline", systemImage: "arrow.down.circle")
                }
            }

            if WorkWindowValue.isSupported, isReal {
                Button {
                    openInWindow()
                } label: {
                    Label("Open in New Window", systemImage: "macwindow.badge.plus")
                }
            }

            if let ao3URL {
                Divider()
                Button {
                    ExternalLinkOpener.open(ao3URL, bridge: state.bridge)
                } label: {
                    Label("Open on AO3", systemImage: "arrow.up.right")
                }
                ShareLink(item: ao3URL) {
                    Label("Share Link", systemImage: "square.and.arrow.up")
                }
                if isDownloaded {
                    Button {
                        exportEpub()
                    } label: {
                        Label("Export as EPUB…", systemImage: "book.closed")
                    }
                }
            }
        } label: {
            Image(systemName: "ellipsis")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(theme.ink2)
                .frame(width: 36, height: 36)
        }
    }

    private var inReadingList: Bool {
        guard let workId = UInt64(workID) else { return false }
        return !state.readingListIDs(forWork: workId).isEmpty
    }

    private var commentsLabel: String {
        guard let work, work.comments > 0 else { return "Comments" }
        return "Comments · \(work.comments.abbreviated)"
    }

    /// Subscribe / unsubscribe on AO3 — a real account change, so
    /// unsubscribing confirms first. Signed-out users see why it's off.
    @ViewBuilder
    private var subscribeItem: some View {
        let subscribed = state.isSubscribedToWork(workID)
        let toggling = state.subscriptionTogglingWorkIDs.contains(workID)
        if state.ao3Username == nil {
            Button {} label: {
                Label("Sign in to Subscribe", systemImage: "bell.slash")
            }
            .disabled(true)
        } else {
            Button {
                if subscribed {
                    showUnsubscribeConfirm = true
                } else {
                    state.toggleWorkSubscription(workID)
                }
            } label: {
                Label(subscribed ? "Unsubscribe on AO3" : "Subscribe on AO3",
                      systemImage: subscribed ? "bell.fill" : "bell")
            }
            .disabled(!isReal || toggling)
        }
    }

    /// Open (or surface) this work's own window at its saved chapter.
    private func openInWindow() {
        let posted = max(1, work?.chapterCount ?? 1)
        let chapter = max(0, min((progress?.chapter ?? 1) - 1, posted - 1))
        openWindow(value: WorkWindowValue(workID: workID, chapterIndex: chapter))
    }

    private func exportEpub() {
        guard let work else { return }
        do {
            exportedEpub = try EpubExporter.export(work: work, appState: state)
        } catch {
            exportError = error.localizedDescription
        }
    }

    // MARK: - Hero Section

    private func heroSection(_ work: Work) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(work.title)
                .font(Typography.detailTitle())
                .foregroundStyle(theme.ink)

            bylineRow(work)

            if state.kudosFailedWorkID == workID {
                kudosFailureBanner
            }

            VStack(alignment: .leading, spacing: 2) {
                ForEach(work.fandomList, id: \.self) { fandom in
                    Text(fandom)
                        .font(Typography.uiCaption())
                        .foregroundStyle(theme.ink3)
                        .textCase(.uppercase)
                        .tracking(0.5)
                }
            }

            if !work.relationship.isEmpty {
                Text(work.relationship)
                    .font(Typography.uiBody())
                    .foregroundStyle(theme.ink2)
            }

            if !work.series.isEmpty {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(work.series, id: \.self) { s in
                        seriesLine(s)
                    }
                }
            }
        }
        .padding(.top, 8)
    }

    /// "by Author" opens the profile; the bell is the local follow (Authors
    /// → Following), never an AO3 subscription.
    private func bylineRow(_ work: Work) -> some View {
        let canOpen = isReal && !work.author.isEmpty
        let following = follows.followedAuthorNames.contains(work.author)
        return HStack(spacing: 8) {
            Button {
                nav.libraryPath.append(AppDestination.authorWorks(
                    username: AppState.canonicalAuthorUsername(work.author)))
            } label: {
                (Text("by ").foregroundStyle(theme.ink2)
                    + Text(work.author).foregroundStyle(theme.accent).fontWeight(.semibold))
                    .font(Typography.uiBody())
            }
            .buttonStyle(.plain)
            .disabled(!canOpen)
            .accessibilityLabel("View \(work.author)’s profile")

            if canOpen {
                Button {
                    if following {
                        follows.unfollowAuthor(work.author)
                    } else {
                        follows.followAuthor(work.author)
                    }
                } label: {
                    Image(systemName: following ? "bell.fill" : "bell")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(following ? theme.accent : theme.ink3)
                        .frame(width: 28, height: 28)
                        .contentShape(Rectangle())
                }
                .buttonStyle(IconButtonPressStyle())
                .accessibilityLabel(following ? "Unfollow \(work.author)" : "Follow \(work.author)")
            }
        }
    }

    private var kudosFailureBanner: some View {
        HStack(spacing: 8) {
            Text(state.kudosFailedIsRetryable
                 ? "Couldn’t reach the archive to leave kudos."
                 : "Couldn’t leave kudos — the archive rejected the request.")
                .font(Typography.uiSmall())
                .foregroundStyle(Color(hex: "CE514D"))
                .fixedSize(horizontal: false, vertical: true)
            if state.kudosFailedIsRetryable {
                Button("Retry") { state.giveKudos(workID) }
                    .font(Typography.smallButtonLabel())
                    .foregroundStyle(theme.accent)
                    .buttonStyle(ButtonPressStyle())
            }
        }
        .padding(.vertical, 4)
    }

    /// "Part N of Series" opens the series' stored works (the Subscriptions
    /// drill-in, which crawls the series on refresh).
    private func seriesLine(_ s: SeriesInfo) -> some View {
        let label = s.part > 0 ? "Part \(s.part) of \(s.name)" : "Part of \(s.name)"
        let canOpen = !s.seriesID.isEmpty && UInt64(s.seriesID) != nil
        return Button {
            nav.openSubscriptionWorks(id: s.seriesID, name: s.name, subType: "series")
        } label: {
            HStack(spacing: 4) {
                Text(label)
                    .font(Typography.uiCaption())
                    .foregroundStyle(canOpen ? theme.accent : theme.ink2)
                    .multilineTextAlignment(.leading)
                if canOpen {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(theme.ink3)
                }
            }
        }
        .buttonStyle(.plain)
        .disabled(!canOpen)
    }

    // MARK: - Meta Pills

    private func metaPills(_ work: Work) -> some View {
        FlowLayout(spacing: 6) {
            ratingPill(work.rating)
            warningPill(work.warnings)
            statusPill(work.complete)
            if !work.updated.isEmpty {
                textPill("Updated \(work.updated)", fg: theme.ink3)
            }
            if let fetched = DBTimestamp.relative(work.fetchedAt) {
                textPill("Fetched \(fetched)", fg: theme.ink3)
            }
            if state.goneWorkIDs.contains(workID) {
                textPill("No longer on AO3", icon: "archivebox", fg: theme.accent2,
                         bg: theme.accent2.opacity(0.13))
            }
        }
    }

    private func ratingPill(_ rating: Rating) -> some View {
        HStack(spacing: 5) {
            RatingBadgeView(rating: rating)
            Text(rating.rawValue)
                .font(Typography.uiSmall())
                .foregroundStyle(theme.ink)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: Radius.chip)
                .fill(theme.surface2)
        )
    }

    private func warningPill(_ warnings: String) -> some View {
        let isChooseNot = warnings == ArchiveWarning.chooseNot.rawValue
        let warnOK = warnings.contains("No Archive")
        return HStack(spacing: 5) {
            Image(systemName: warnOK ? "checkmark.shield" : "eye")
                .font(.system(size: 11, weight: .medium))
            Text(warnOK ? "No warnings" : warnings)
        }
        .font(Typography.uiSmall())
        .foregroundStyle(isChooseNot || !warnOK ? theme.accent2 : theme.sage)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: Radius.chip)
                .fill(theme.surface2)
        )
    }

    private func statusPill(_ complete: Bool) -> some View {
        HStack(spacing: 4) {
            Circle()
                .fill(complete ? theme.sage : theme.accent2)
                .frame(width: 6, height: 6)
            Text(complete ? "Complete" : "Work in Progress")
                .font(Typography.uiSmall())
                .foregroundStyle(theme.ink2)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: Radius.chip)
                .fill(theme.surface2)
        )
    }

    private func textPill(_ label: String, icon: String? = nil, fg: Color, bg: Color? = nil) -> some View {
        HStack(spacing: 5) {
            if let icon {
                Image(systemName: icon).font(.system(size: 11, weight: .medium))
            }
            Text(label)
        }
        .font(Typography.uiSmall())
        .foregroundStyle(fg)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: Radius.chip)
                .fill(bg ?? theme.surface2)
        )
    }

    // MARK: - Stats

    private func statsSection(_ work: Work) -> some View {
        StatGridView(stats: [
            ("Words", work.words.abbreviated),
            ("Chapters", "\(work.chapterCount)/\(work.complete ? String(work.totalChapters) : "?")"),
            ("Kudos", work.kudos.abbreviated),
            ("Saved", work.bookmarks.abbreviated),
        ])
    }

    // MARK: - Summary

    @ViewBuilder
    private func summarySection(_ work: Work) -> some View {
        if !work.summary.isEmpty {
            SummaryBoxView(summary: work.summary)
        }
    }

    // MARK: - Tags

    private func tagFlow(_ work: Work) -> some View {
        FlowLayout(spacing: 8) {
            // Fandom tags — one chip per fandom, each opening its own tag
            ForEach(work.fandomList, id: \.self) { fandom in
                Button { nav.openTag(fandom) } label: {
                    Text(fandom)
                        .font(Typography.uiSmall())
                        .foregroundStyle(theme.accent)
                        .lineLimit(1)
                        .padding(.horizontal, 12)
                        .frame(height: 30)
                        .background(
                            RoundedRectangle(cornerRadius: Radius.chip)
                                .fill(theme.accentSoft)
                        )
                }
                .buttonStyle(ChipPressStyle())
            }

            ForEach(work.tags, id: \.self) { tag in
                Button { nav.openTag(tag) } label: {
                    Text(tag)
                        .font(Typography.uiSmall())
                        .foregroundStyle(theme.ink)
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .padding(.horizontal, 12)
                        .frame(height: 30)
                        .background(
                            RoundedRectangle(cornerRadius: Radius.chip)
                                .fill(theme.surface)
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: Radius.chip)
                                .stroke(theme.line, lineWidth: 1)
                        )
                }
                .buttonStyle(ChipPressStyle())
            }
        }
        .clipped()
    }

    // MARK: - Engagement Row

    private func engagementRow(_ work: Work) -> some View {
        let kudosRed = Color(hex: "CE514D")
        return HStack(spacing: 16) {
            // Kudos — one-way; permanent on AO3. Empty = none (or the POST
            // failed), faded = request in flight, full = AO3 confirmed.
            Button {
                state.giveKudos(workID)
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: hasKudos || kudosPending ? "heart.fill" : "heart")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(hasKudos ? kudosRed
                                         : kudosPending ? kudosRed.opacity(0.45) : theme.ink3)
                    Text(work.kudos.abbreviated)
                        .font(Typography.uiSmall())
                        .foregroundStyle(theme.ink2)
                }
            }
            .buttonStyle(IconButtonPressStyle())
            .disabled(!isReal || hasKudos || kudosPending)
            .accessibilityLabel(hasKudos ? "Kudos left — kudos are permanent on AO3"
                                : kudosPending ? "Leaving kudos…" : "Leave kudos on AO3")

            // Comments for the whole work
            Button {
                nav.presentedSheet = .viewComments(workID: workID, chapterID: nil)
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: "bubble.right")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(theme.ink3)
                    Text(work.comments.abbreviated)
                        .font(Typography.uiSmall())
                        .foregroundStyle(theme.ink2)
                }
            }
            .buttonStyle(IconButtonPressStyle())
            .disabled(!isReal)

            Spacer()

            if state.isDownloading(workID) {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small).tint(theme.ink3)
                    Text("Downloading…")
                        .font(Typography.uiSmall())
                        .foregroundStyle(theme.ink3)
                }
            } else if isDownloaded {
                HStack(spacing: 5) {
                    Image(systemName: "checkmark.circle")
                        .font(.system(size: 13, weight: .medium))
                    Text("Downloaded")
                        .font(Typography.uiSmall())
                }
                .foregroundStyle(theme.sage)
            }
        }
    }

    // MARK: - Chapters

    private var currentChapterSelection: Int {
        progress?.chapter ?? 1
    }

    private func chaptersSection(_ work: Work) -> some View {
        let posted = max(1, work.chapterCount)
        return VStack(alignment: .leading, spacing: 12) {
            SectionHeaderView(title: "Chapters")

            HStack(spacing: 12) {
                Menu {
                    ForEach(1...posted, id: \.self) { num in
                        let title = chapterTitle(num, work: work)
                        let isRead: Bool = {
                            guard let p = progress else { return false }
                            return num < p.chapter
                        }()

                        Button {
                            nav.openReader(workID, chapterIndex: num - 1)
                        } label: {
                            HStack {
                                Text(title == "Chapter \(num)" ? title : "\(num) · \(title)")
                                if isRead {
                                    Image(systemName: "checkmark")
                                }
                            }
                        }
                    }
                } label: {
                    HStack {
                        Text("Ch. \(min(currentChapterSelection, posted)) of \(posted)")
                            .font(.custom("HankenGrotesk", size: 14).weight(.semibold))
                            .foregroundStyle(theme.ink)
                        Spacer()
                        Image(systemName: "chevron.up.chevron.down")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(theme.ink3)
                    }
                    .padding(.horizontal, 14)
                    .frame(height: 44)
                    .background(theme.surface2)
                    .clipShape(RoundedRectangle(cornerRadius: 10))
                }

                if progress != nil {
                    Button {
                        state.resetProgress(workID)
                    } label: {
                        Image(systemName: "arrow.counterclockwise")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(theme.ink3)
                            .frame(width: 44, height: 44)
                            .background(theme.surface2)
                            .clipShape(RoundedRectangle(cornerRadius: 10))
                    }
                    .buttonStyle(IconButtonPressStyle())
                    .accessibilityLabel("Reset reading progress")
                }
            }

            if work.totalChapters > work.chapterCount {
                Text("\(work.totalChapters - work.chapterCount) more not posted yet")
                    .font(Typography.uiCaption())
                    .foregroundStyle(theme.ink3)
            }
        }
    }

    /// Titles come from the session cache when this work's chapters were
    /// fetched this run, else from the chapters persisted in the encrypted
    /// DB by any earlier session's fetch or download.
    private func chapterTitle(_ num: Int, work: Work) -> String {
        let index = num - 1
        let stored: String = {
            if let fetched = state.chaptersForWork(workID), index < fetched.count {
                return fetched[index].title
            }
            if let workId = UInt64(workID) {
                let cached = state.bridge.getCachedChapters(workId)
                if index < cached.count { return cached[index].title }
            }
            if let content = work.content, index < content.count {
                return content[index].title
            }
            return ""
        }()
        return stored.isEmpty ? "Chapter \(num)" : stored
    }

    // MARK: - Bottom Bar

    private func bottomBar(_ work: Work) -> some View {
        VStack(spacing: 0) {
            Divider()
                .foregroundStyle(theme.line)

            HStack(spacing: 12) {
                // Download button
                Button { state.toggleDownload(workID) } label: {
                    Group {
                        if state.isDownloading(workID) {
                            ProgressView().controlSize(.small).tint(theme.ink2)
                        } else {
                            Image(systemName: isDownloaded ? "checkmark.circle" : "arrow.down.circle")
                                .font(.system(size: 22, weight: .medium))
                                .foregroundStyle(isDownloaded ? theme.sage : theme.ink2)
                        }
                    }
                    .frame(width: 48, height: 48)
                    .background(
                        RoundedRectangle(cornerRadius: Radius.button)
                            .stroke(theme.line, lineWidth: 1)
                    )
                }
                .buttonStyle(ButtonPressStyle())
                .accessibilityLabel(isDownloaded ? "Downloaded" : "Download for offline")

                // Entire work button
                if work.chapterCount > 1 {
                    Button { nav.openEntireWork(workID) } label: {
                        Image(systemName: "book.pages.fill")
                            .font(.system(size: 22, weight: .medium))
                            .foregroundStyle(theme.ink2)
                            .frame(width: 48, height: 48)
                            .background(
                                RoundedRectangle(cornerRadius: Radius.button)
                                    .stroke(theme.line, lineWidth: 1)
                            )
                    }
                    .buttonStyle(ButtonPressStyle())
                    .accessibilityLabel("Read entire work")
                }

                // Primary action button
                Button {
                    // iPad: the reading-settings choice sends works to their
                    // own windows instead of the reading column.
                    if WorkWindowValue.isSupported, theme.openWorksInWindow, isReal {
                        openInWindow()
                        return
                    }
                    let chapter = max(0, min((progress?.chapter ?? 1) - 1, max(0, work.chapterCount - 1)))
                    nav.openReader(workID, chapterIndex: chapter)
                } label: {
                    Text(primaryButtonLabel)
                        .font(Typography.buttonLabel())
                        .foregroundStyle(theme.onAccent)
                        .frame(maxWidth: .infinity)
                        .frame(height: 48)
                        .background(
                            RoundedRectangle(cornerRadius: Radius.button)
                                .fill(theme.accent)
                        )
                }
                .buttonStyle(ButtonPressStyle())
            }
            .padding(.horizontal, theme.pad)
            .padding(.vertical, 12)
            .background(theme.surface.shadow(.drop(color: .black.opacity(0.06), radius: 8, y: -4)))
        }
    }

    private var primaryButtonLabel: String {
        if let p = progress, p.pos > 0 || p.chapter > 1 {
            return "Continue \u{00B7} Ch. \(p.chapter)"
        }
        return "Start reading"
    }
}

// MARK: - Flow Layout

/// A simple flow/wrapping layout for pills and tags.
struct FlowLayout: Layout {
    var spacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let result = layout(in: proposal.width ?? 0, subviews: subviews)
        return result.size
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let result = layout(in: bounds.width, subviews: subviews)
        for (index, position) in result.positions.enumerated() {
            let natural = subviews[index].sizeThatFits(.unspecified)
            let clamped = CGSize(width: min(natural.width, bounds.width), height: natural.height)
            subviews[index].place(
                at: CGPoint(x: bounds.minX + position.x, y: bounds.minY + position.y),
                proposal: ProposedViewSize(clamped)
            )
        }
    }

    private func layout(in maxWidth: CGFloat, subviews: Subviews) -> (size: CGSize, positions: [CGPoint]) {
        var positions: [CGPoint] = []
        var x: CGFloat = 0
        var y: CGFloat = 0
        var rowHeight: CGFloat = 0
        var maxX: CGFloat = 0

        for subview in subviews {
            let natural = subview.sizeThatFits(.unspecified)
            let size = CGSize(width: min(natural.width, maxWidth), height: natural.height)
            if x + size.width > maxWidth, x > 0 {
                x = 0
                y += rowHeight + spacing
                rowHeight = 0
            }
            positions.append(CGPoint(x: x, y: y))
            rowHeight = max(rowHeight, size.height)
            x += size.width + spacing
            maxX = max(maxX, x - spacing)
        }

        return (CGSize(width: maxX, height: y + rowHeight), positions)
    }
}

#Preview {
    NavigationStack {
        WorkDetailView(workID: "baker")
    }
    .environment(AppTheme())
    .environment(AppState())
    .environment(NavigationState())
}
