import SwiftUI

struct WorkCardView: View {
    @Environment(AppTheme.self) private var theme
    @Environment(AppState.self) private var appState

    let work: Work
    var blurExplicit: Bool = false
    var onTap: () -> Void

    @State private var revealed = false

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
                    .stroke(theme.line, lineWidth: 1)
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
                // Fandom label
                Text(work.fandom)
                    .font(.custom("HankenGrotesk", size: 11.5).weight(.semibold))
                    .foregroundStyle(theme.ink3)
                    .textCase(.uppercase)
                    .tracking(0.5)

                // Title
                Text(work.title)
                    .font(Typography.workTitle())
                    .foregroundStyle(theme.ink)
                    .lineLimit(2)

                // Byline
                Text("by \(work.author)")
                    .font(.custom("HankenGrotesk", size: 13).weight(.medium))
                    .foregroundStyle(theme.ink2)

                // Summary
                if !work.summary.isEmpty {
                    Text(work.summary)
                        .font(.custom("HankenGrotesk", size: 13))
                        .foregroundStyle(theme.ink3)
                        .lineLimit(2)
                }

                // Tags
                tagRow

                // Stats
                statRow
            }

            RatingBadgeView(rating: work.rating)
        }
    }

    private var tagRow: some View {
        FlowLayout(spacing: 5) {
            ForEach(work.tags, id: \.self) { tag in
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
        }
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
        tags: ["Slow Burn", "Victorian", "Case Fic", "Mutual Pining"],
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
    WorkCardView(work: work, onTap: {})
        .padding()
        .environment(AppTheme())
        .environment(AppState())
}
