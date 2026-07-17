import SwiftUI

struct WorkDetailView: View {
    @Environment(AppTheme.self) private var theme
    @Environment(AppState.self) private var state
    @Environment(NavigationState.self) private var nav
    @Environment(\.dismiss) private var dismiss

    let workID: String

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

    private var isLiveWork: Bool {
        UInt64(workID) != nil && work?.content == nil
    }

    var body: some View {
        ZStack(alignment: .top) {
            if let work {
                ScrollView {
                    VStack(alignment: .leading, spacing: theme.rowGap) {
                        Spacer()
                            .frame(height: 56)

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
                    .padding(.bottom, 16)
                }

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
                NetworkLoadingView(message: "Loading work...", task: state.metadataTask, operation: "work") {
                    state.metadataTask.cancel()
                }
                .frame(maxHeight: .infinity)
            }

            topChrome
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(theme.bg)
        .navigationBarBackButtonHidden(true)
        .toolbar(.hidden, for: .tabBar)
        .toolbar(.hidden, for: .navigationBar)
        .task(id: workID) {
            if isLiveWork {
                await state.fetchWorkMetadata(workID)
            }
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

            Button { nav.goHome() } label: {
                Image(systemName: "house")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(theme.ink2)
                    .frame(width: 36, height: 36)
            }
            .buttonStyle(IconButtonPressStyle())

            Spacer()

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

            Button { state.toggleDownload(workID) } label: {
                Image(systemName: isDownloaded ? "arrow.down.circle.fill" : "arrow.down.circle")
                    .font(.system(size: 17, weight: .medium))
                    .foregroundStyle(isDownloaded ? theme.sage : theme.ink2)
                    .frame(width: 36, height: 36)
            }
            .buttonStyle(IconButtonPressStyle())

            if !state.readingLists.isEmpty {
                Menu {
                    ForEach(state.readingLists, id: \.id) { list in
                        Button {
                            state.addToReadingList(list.id, workId: workID)
                        } label: {
                            Label(list.name, systemImage: "text.badge.plus")
                        }
                    }
                } label: {
                    Image(systemName: "text.badge.plus")
                        .font(.system(size: 15, weight: .medium))
                        .foregroundStyle(theme.ink2)
                        .frame(width: 36, height: 36)
                }
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

    // MARK: - Hero Section

    private func heroSection(_ work: Work) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(work.fandom)
                .font(Typography.uiCaption())
                .foregroundStyle(theme.ink3)
                .textCase(.uppercase)
                .tracking(0.5)

            Text(work.title)
                .font(Typography.detailTitle())
                .foregroundStyle(theme.ink)

            Text("by \(work.author)")
                .font(Typography.uiBody())
                .foregroundStyle(theme.accent)

            if !work.relationship.isEmpty {
                Text(work.relationship)
                    .font(Typography.uiBody())
                    .foregroundStyle(theme.ink2)
            }
        }
        .padding(.top, 8)
    }

    // MARK: - Meta Pills

    private func metaPills(_ work: Work) -> some View {
        FlowLayout(spacing: 6) {
            // Rating pill
            ratingPill(work.rating)

            // Warning pill
            warningPill(work.warnings)

            // Complete/WIP pill
            statusPill(work.complete)
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
        return Text(warnings)
            .font(Typography.uiSmall())
            .foregroundStyle(isChooseNot ? theme.accent2 : theme.sage)
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

    // MARK: - Stats

    private func statsSection(_ work: Work) -> some View {
        StatGridView(stats: [
            ("Words", work.words.abbreviated),
            ("Chapters", "\(work.chapterCount)/\(work.totalChapters)"),
            ("Kudos", work.kudos.abbreviated),
            ("Saved", work.bookmarks.abbreviated),
        ])
    }

    // MARK: - Summary

    private func summarySection(_ work: Work) -> some View {
        SummaryBoxView(summary: work.summary)
        }

    // MARK: - Tags

    private func tagFlow(_ work: Work) -> some View {
        FlowLayout(spacing: 8) {
            // Fandom tag
            Button { nav.openTag(work.fandom) } label: {
                Text(work.fandom)
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
        HStack(spacing: 16) {
            // Kudos — one-way; permanent on AO3
            Button {
                state.giveKudos(workID)
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: hasKudos ? "heart.fill" : "heart")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(hasKudos ? theme.accent : theme.ink3)
                    Text(work.kudos.abbreviated)
                        .font(Typography.uiSmall())
                        .foregroundStyle(theme.ink2)
                }
            }
            .buttonStyle(IconButtonPressStyle())
            .disabled(hasKudos)

            // Comments (read-only count — commenting is per-chapter in the reader)
            HStack(spacing: 5) {
                Image(systemName: "bubble.right")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(theme.ink3)
                Text("\(work.comments)")
                    .font(Typography.uiSmall())
                    .foregroundStyle(theme.ink2)
            }

            Spacer()

            // Updated date
            Text("Updated \(work.updated)")
                .font(Typography.uiSmall())
                .foregroundStyle(theme.ink3)
        }
    }

    // MARK: - Chapters

    private var currentChapterSelection: Int {
        progress?.chapter ?? 1
    }

    private func chaptersSection(_ work: Work) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionHeaderView(title: "Chapters")

            HStack(spacing: 12) {
                Menu {
                    ForEach(1...work.chapterCount, id: \.self) { num in
                        let fetchedChs = state.chaptersForWork(workID)
                        let title: String = {
                            if let fetched = fetchedChs, num - 1 < fetched.count, !fetched[num - 1].title.isEmpty {
                                return fetched[num - 1].title
                            }
                            return "Chapter \(num)"
                        }()
                        let isRead: Bool = {
                            guard let p = progress else { return false }
                            return num < p.chapter || (num == p.chapter && p.pct >= 0.99)
                        }()

                        Button {
                            nav.openReader(workID, chapterIndex: num - 1)
                        } label: {
                            HStack {
                                Text("Ch. \(num): \(title)")
                                if isRead {
                                    Image(systemName: "checkmark")
                                }
                            }
                        }
                    }
                } label: {
                    HStack {
                        Text("Ch. \(currentChapterSelection) of \(work.chapterCount)")
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
                }
            }
        }
    }

    // MARK: - Bottom Bar

    private func bottomBar(_ work: Work) -> some View {
        VStack(spacing: 0) {
            Divider()
                .foregroundStyle(theme.line)

            HStack(spacing: 12) {
                // Download button
                Button { state.toggleDownload(workID) } label: {
                    Image(systemName: isDownloaded ? "arrow.down.circle.fill" : "arrow.down.circle")
                        .font(.system(size: 22, weight: .medium))
                        .foregroundStyle(isDownloaded ? theme.sage : theme.ink2)
                        .frame(width: 48, height: 48)
                        .background(
                            RoundedRectangle(cornerRadius: Radius.button)
                                .stroke(theme.line, lineWidth: 1)
                        )
                }
                .buttonStyle(ButtonPressStyle())

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
                }

                // Primary action button
                Button {
                    if let p = progress {
                        nav.openReader(workID, chapterIndex: p.chapter - 1)
                    } else {
                        nav.openReader(workID, chapterIndex: 0)
                    }
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
        if let p = progress, p.pct > 0 {
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
