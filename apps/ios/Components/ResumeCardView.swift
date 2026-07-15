import SwiftUI

struct ResumeCardView: View {
    @Environment(AppTheme.self) private var theme

    let work: Work
    let progress: ReadingProgress
    var chapter: String? = nil
    var onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            VStack(alignment: .leading, spacing: 10) {
                // Eyebrow
                HStack(spacing: 5) {
                    Image(systemName: "book")
                        .font(.system(size: 11, weight: .semibold))
                    Text("CONTINUE READING")
                        .font(.custom("HankenGrotesk", size: 11).weight(.bold))
                        .tracking(0.5)
                }
                .foregroundStyle(theme.accent)

                // Title
                Text(work.title)
                    .font(Typography.resumeTitle())
                    .foregroundStyle(theme.ink)
                    .lineLimit(2)

                // Chapter and author meta
                HStack(spacing: 0) {
                    if let chapter {
                        Text(chapter)
                            .foregroundStyle(theme.ink2)
                        Text(" \u{2022} ")
                            .foregroundStyle(theme.ink3)
                    }
                    Text(work.author)
                        .foregroundStyle(theme.ink2)
                }
                .font(.custom("HankenGrotesk", size: 13).weight(.medium))
                .lineLimit(1)

                // Progress bar + percentage
                HStack(spacing: 10) {
                    ProgressTrackView(progress: progress.pct)

                    Text("\(Int(progress.pct * 100))%")
                        .font(.custom("HankenGrotesk", size: 12).weight(.bold))
                        .foregroundStyle(theme.ink2)
                }
            }
            .padding(theme.cardPad)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                LinearGradient(
                    colors: [theme.accentSoft, theme.surface],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
            )
            .clipShape(RoundedRectangle(cornerRadius: Radius.resumeCard))
            .overlay(
                RoundedRectangle(cornerRadius: Radius.resumeCard)
                    .stroke(theme.line, lineWidth: 1)
            )
        }
        .buttonStyle(CardPressStyle())
    }
}

#Preview {
    let work = Work(
        id: "preview",
        title: "The Adventure of the Empty House",
        author: "gaslight_gatekeep",
        fandom: "Sherlock Holmes — A.C. Doyle",
        relationship: "Holmes/Watson",
        rating: .general,
        warnings: "No Archive Warnings Apply",
        category: "M/M",
        tags: ["Victorian"],
        words: 42000,
        chapterCount: 8,
        totalChapters: 12,
        complete: false,
        kudos: 1200,
        hits: 8000,
        bookmarks: 200,
        comments: 80,
        published: "2023-10-12",
        updated: "2024-02-01",
        summary: "A return to Baker Street.",
        initialProgress: 0.38,
        lastChapter: 4,
        downloaded: false,
        content: nil
    )
    ResumeCardView(
        work: work,
        progress: ReadingProgress(chapter: 4, pct: 0.38),
        chapter: "Ch. 4: The Empty House",
        onTap: {}
    )
    .padding()
    .environment(AppTheme())
}
