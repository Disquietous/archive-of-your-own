import SwiftUI

struct WorkCardView: View {
    @Environment(AppTheme.self) private var theme
    @Environment(AppState.self) private var appState
    @Environment(FollowModel.self) private var follows: FollowModel?

    let work: Work
    var blurExplicit: Bool = false
    /// What's New: unseen since the last visit.
    var isNew: Bool = false
    /// The work is gone from AO3 (deleted or hidden) since it was cached.
    var isRemoved: Bool = false
    /// Byline follow bell (device-local follow; needs a `FollowModel` in
    /// the environment to appear).
    var showsFollowBell: Bool = true
    /// Quick bookmark toggle on the stat row.
    var showsBookmarkToggle: Bool = true
    /// Tap on the byline (open the author).
    var onAuthorTap: (() -> Void)? = nil
    var onTap: () -> Void

    @State private var revealed = false
    @State private var summaryExpanded = false
    @State private var tagsExpanded = false

    /// Tags shown while the tag row is collapsed.
    private static let collapsedTagCount = 4

    var body: some View {
        Button(action: {
            if isGated {
                withAnimation(.easeInOut(duration: 0.2)) {
                    revealed = true
                }
            } else {
                onTap()
            }
        }) {
            HStack(spacing: 0) {
                // Spine
                RoundedRectangle(cornerRadius: 2)
                    .fill(work.spineColor)
                    .frame(width: 4)

                // Body
                cardBody
                    .padding(theme.cardPad)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .background(theme.surface)
            .clipShape(RoundedRectangle(cornerRadius: Radius.card))
            .overlay(
                RoundedRectangle(cornerRadius: Radius.card)
                    .stroke(isNew ? theme.accent.opacity(0.5) : theme.line, lineWidth: 1)
            )
        }
        .buttonStyle(CardPressStyle())
    }

    private var isGated: Bool {
        blurExplicit && work.rating == .explicit && !revealed
    }

    @ViewBuilder
    private var cardBody: some View {
        if isGated {
            gatedContent
        } else {
            normalContent
        }
    }

    private var gatedContent: some View {
        VStack(spacing: 8) {
            Image(systemName: "eye.slash")
                .font(.system(size: 24))
                .foregroundStyle(theme.ink3)
            Text("Explicit work hidden")
                .font(.custom("HankenGrotesk", size: 14).weight(.semibold))
                .foregroundStyle(theme.ink3)
            Text("Tap to reveal")
                .font(.custom("HankenGrotesk", size: 12).weight(.medium))
                .foregroundStyle(theme.ink3.opacity(0.7))
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 24)
    }

    private var normalContent: some View {
        ZStack(alignment: .topTrailing) {
            VStack(alignment: .leading, spacing: 6) {
                // Fandom label + status pills
                HStack(spacing: 6) {
                    Text(work.fandomDisplay)
                        .font(.custom("HankenGrotesk", size: 11.5).weight(.semibold))
                        .foregroundStyle(theme.ink3)
                        .textCase(.uppercase)
                        .tracking(0.5)
                        .lineLimit(1)
                    if isNew { pill("NEW", fill: theme.accent, ink: theme.onAccent) }
                    if isRemoved { pill("REMOVED", fill: theme.ink3, ink: theme.surface) }
                }
                .padding(.trailing, 44)  // clear the rating badge

                // Title
                Text(work.title)
                    .font(Typography.workTitle())
                    .foregroundStyle(theme.ink)
                    .lineLimit(2)

                // Byline + follow bell
                bylineRow

                // Summary (tap to expand/collapse)
                if !work.summary.isEmpty {
                    Text(work.summary)
                        .font(.custom("HankenGrotesk", size: 13))
                        .foregroundStyle(theme.ink3)
                        .lineLimit(summaryExpanded ? nil : 2)
                        .fixedSize(horizontal: false, vertical: true)
                        .contentShape(Rectangle())
                        .onTapGesture {
                            withAnimation(.easeInOut(duration: 0.2)) { summaryExpanded.toggle() }
                        }
                }

                // Tags
                tagRow

                // Stats + bookmark toggle
                statRow

                // Progress
                let progress = appState.progress(for: work)
                if progress > 0 {
                    ProgressTrackView(progress: progress)
                        .padding(.top, 2)
                }
            }

            RatingBadgeView(rating: work.rating)
        }
    }

    private func pill(_ text: String, fill: Color, ink: Color) -> some View {
        Text(text)
            .font(.custom("HankenGrotesk", size: 9.5).weight(.bold))
            .tracking(0.4)
            .foregroundStyle(ink)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(fill)
            .clipShape(Capsule())
    }

    private var bylineRow: some View {
        HStack(spacing: 6) {
            if let onAuthorTap {
                Button(action: onAuthorTap) {
                    Text("by \(work.author)")
                        .font(.custom("HankenGrotesk", size: 13).weight(.medium))
                        .foregroundStyle(theme.ink2)
                        .lineLimit(1)
                }
                .buttonStyle(.plain)
            } else {
                Text("by \(work.author)")
                    .font(.custom("HankenGrotesk", size: 13).weight(.medium))
                    .foregroundStyle(theme.ink2)
                    .lineLimit(1)
            }
            if showsFollowBell, let follows, !work.author.isEmpty {
                let followState = follows.authorFollowState(work.author)
                Button {
                    follows.toggleAuthorFollow(work.author)
                } label: {
                    Image(systemName: followState.shaded ? "bell.fill" : "bell")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(followState.shaded ? theme.accent : theme.ink3)
                        .frame(width: 22, height: 22)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(followState == .followed ? "Unfollow author" : "Follow author")
            }
        }
    }

    private var tagRow: some View {
        let tags = work.tags
        let collapsed = !tagsExpanded && tags.count > Self.collapsedTagCount
        let shown = collapsed ? Array(tags.prefix(Self.collapsedTagCount)) : tags
        return FlowLayout(spacing: 5) {
            ForEach(shown, id: \.self) { tag in
                tagChip(tag)
            }
            if collapsed {
                tagChip("+\(tags.count - Self.collapsedTagCount)")
            }
        }
        .contentShape(Rectangle())
        .onTapGesture {
            guard tags.count > Self.collapsedTagCount else { return }
            withAnimation(.easeInOut(duration: 0.2)) { tagsExpanded.toggle() }
        }
    }

    private func tagChip(_ tag: String) -> some View {
        Text(tag)
            .font(.custom("HankenGrotesk", size: 11.5).weight(.medium))
            .foregroundStyle(theme.ink2)
            .lineLimit(1)
            .truncationMode(.tail)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(theme.surface2)
            .clipShape(RoundedRectangle(cornerRadius: Radius.chip))
    }

    private var statRow: some View {
        HStack(spacing: 10) {
            statItem(icon: "heart", value: work.kudos.abbreviated)
            statItem(icon: "text.word.spacing", value: work.words.abbreviated)

            let chapterText = work.totalChapters > 0
                ? "\(work.chapterCount)/\(work.totalChapters)"
                : "\(work.chapterCount)/?"
            statItem(icon: "book", value: chapterText)

            if appState.downloadedWorkIDs.contains(work.id) {
                HStack(spacing: 3) {
                    Image(systemName: "arrow.down.circle.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(theme.sage)
                    Text("Offline")
                        .font(.custom("HankenGrotesk", size: 11).weight(.semibold))
                        .foregroundStyle(theme.sage)
                }
            }

            Spacer()

            if showsBookmarkToggle {
                let bookmarked = appState.bookmarkedWorkIDs.contains(work.id)
                Button {
                    appState.toggleBookmark(work.id)
                } label: {
                    Image(systemName: bookmarked ? "bookmark.fill" : "bookmark")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(bookmarked ? theme.accent : theme.ink3)
                        .frame(width: 24, height: 24)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(bookmarked ? "Remove bookmark" : "Bookmark")
            }
        }
        .padding(.top, 2)
    }

    private func statItem(icon: String, value: String) -> some View {
        HStack(spacing: 3) {
            Image(systemName: icon)
                .font(.system(size: 11))
                .foregroundStyle(theme.ink3)
            Text(value)
                .font(.custom("HankenGrotesk", size: 12).weight(.medium))
                .foregroundStyle(theme.ink3)
        }
    }
}

#Preview {
    let work = Work(
        id: "preview",
        title: "A Study in Scarlet Threads",
        author: "gaslight_gatekeep",
        fandom: "Sherlock Holmes — A.C. Doyle",
        relationship: "Holmes/Watson",
        rating: .teen,
        warnings: "No Archive Warnings Apply",
        category: "M/M",
        tags: ["Slow Burn", "Victorian", "Case Fic", "Mutual Pining", "Angst", "Fluff"],
        words: 84210,
        chapterCount: 12,
        totalChapters: 20,
        complete: false,
        kudos: 2847,
        hits: 18503,
        bookmarks: 412,
        comments: 156,
        published: "2023-09-04",
        updated: "2024-01-15",
        summary: "When a series of impossible thefts plague the British Museum, Holmes finds himself entangled in a web of secrets that hits closer to home than he'd like.",
        initialProgress: 0,
        lastChapter: nil,
        downloaded: false,
        content: nil
    )
    WorkCardView(work: work, isNew: true, onTap: {})
        .padding()
        .environment(AppTheme())
        .environment(AppState())
}
