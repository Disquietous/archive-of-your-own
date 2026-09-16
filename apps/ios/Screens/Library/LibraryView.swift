import SwiftUI

/// The Library tab: the hub. One row per macOS sidebar section, grouped
/// the same way, with counts and badges; each row pushes its section
/// screen. The resume card sits above the hub for one-tap continue.
struct LibraryView: View {
    @Environment(AppTheme.self) private var theme
    @Environment(AppState.self) private var state
    @Environment(NavigationState.self) private var nav
    @Environment(FollowModel.self) private var follows

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: theme.rowGap) {
                masthead
                lastCheckedLabel

                if let resume = state.resumeWork,
                   let progress = state.progressMap[resume.id] {
                    ResumeCardView(
                        work: resume,
                        progress: progress,
                        chapter: resumeChapterTitle(for: resume, progress: progress),
                        onTap: {
                            nav.openReader(resume.id, chapterIndex: progress.chapter - 1)
                        }
                    )
                    .padding(.horizontal, theme.pad)
                }

                hubGroup(nil) {
                    hubRow(.reading, "book", "Currently Reading", count: state.currentlyReading.count)
                    hubRow(.history, "clock", "History", count: state.history.count)
                }
                hubGroup("Discover") {
                    hubRow(.fandoms, "flame", "Fandoms", count: follows.followedFandoms.count)
                    hubRow(.authors, "person", "Authors",
                           count: follows.followedAuthorNames.count + state.followedAuthors.count)
                }
                hubGroup("Following") {
                    hubRow(.whatsNew, "bell.badge", "What’s New", badge: state.newUnviewedWorkCount)
                    hubRow(.subscriptions, "bell", "Subscriptions",
                           count: state.ao3Username == nil ? nil : state.subscriptions.count)
                    hubRow(.inbox, "tray", "Inbox", badge: state.inboxUnreadCount)
                }
                hubGroup("Saved") {
                    hubRow(.bookmarks, "bookmark", "Bookmarks", count: state.bookmarkedWorkIDs.count)
                    hubRow(.readingLists, "books.vertical", "Reading Lists", count: state.readingLists.count)
                    hubRow(.downloads, "arrow.down.circle", "Offline", count: state.downloadedWorkIDs.count)
                    hubRow(.stats, "chart.bar", "Reading Stats")
                }
            }
            .padding(.bottom, 32)
        }
        .background { ThemeBackgroundView() }
        .onChange(of: nav.goHomeRequested) { _, requested in
            if requested { nav.goHomeRequested = false }
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
                    Task { await state.checkSubscriptions(force: true) }
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
               let date = DBTimestamp.date(ts) {
                Text("Last checked: \(date.formatted(.relative(presentation: .named)))")
                    .font(.custom("HankenGrotesk", size: 11).weight(.medium))
                    .foregroundStyle(theme.ink3)
                    .padding(.horizontal, theme.pad)
            }
        }
    }

    /// Chapter line for the resume card, from the cached chapters when the
    /// work has been fetched; nil otherwise (the card then shows no chapter).
    private func resumeChapterTitle(for work: Work, progress: ReadingProgress) -> String? {
        guard let chapters = state.chaptersForWork(work.id),
              progress.chapter >= 1, progress.chapter - 1 < chapters.count else { return nil }
        let title = chapters[progress.chapter - 1].title
        return title.isEmpty ? "Chapter \(progress.chapter)" : title
    }

    // MARK: - Hub

    private func hubGroup(_ label: String?, @ViewBuilder rows: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            if let label {
                SectionHeaderView(title: label)
            }
            VStack(spacing: 0) {
                rows()
            }
            .background(theme.surface)
            .clipShape(RoundedRectangle(cornerRadius: Radius.card))
            .overlay(
                RoundedRectangle(cornerRadius: Radius.card)
                    .stroke(theme.line, lineWidth: 1)
            )
        }
        .padding(.horizontal, theme.pad)
    }

    private func hubRow(_ section: LibrarySection, _ icon: String, _ label: String,
                        count: Int? = nil, badge: Int = 0) -> some View {
        Button {
            nav.openLibrarySection(section)
        } label: {
            HStack(spacing: 12) {
                Image(systemName: icon)
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(theme.ink3)
                    .frame(width: 22)
                Text(label)
                    .font(.custom("HankenGrotesk", size: 15).weight(.medium))
                    .foregroundStyle(theme.ink)
                    .lineLimit(1)
                Spacer(minLength: 4)
                if badge > 0 {
                    Text("\(badge)")
                        .font(.custom("HankenGrotesk", size: 11).weight(.bold))
                        .foregroundStyle(theme.onAccent)
                        .padding(.horizontal, 6)
                        .frame(minWidth: 20, minHeight: 20)
                        .background(theme.accent)
                        .clipShape(Capsule())
                } else if let count, count > 0 {
                    Text("\(count)")
                        .font(.custom("HankenGrotesk", size: 12).weight(.semibold))
                        .foregroundStyle(theme.ink3)
                }
                Image(systemName: "chevron.right")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(theme.ink3)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .overlay(alignment: .bottom) {
            if !Self.lastInGroup.contains(section) {
                theme.line.frame(height: 1).padding(.leading, 48)
            }
        }
    }

    /// Rows that close a hub group (no divider beneath).
    private static let lastInGroup: Set<LibrarySection> = [.history, .authors, .inbox, .stats]
}

#Preview {
    let state = AppState()
    LibraryView()
        .environment(AppTheme())
        .environment(state)
        .environment(NavigationState())
        .environment(FollowModel(appState: state))
}
