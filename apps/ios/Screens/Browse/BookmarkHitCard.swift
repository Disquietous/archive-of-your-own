import SwiftUI

/// One public-bookmark hit: the bookmarked work's card (or a series card)
/// with the bookmarker's own note, tags and rec mark underneath.
struct BookmarkHitCard: View {
    @Environment(AppTheme.self) private var theme
    @Environment(AppState.self) private var state
    @Environment(NavigationState.self) private var nav

    let hit: UBookmarkHit
    var onNewReadingList: ((Work) -> Void)?
    var onExportEpub: ((Work) -> Void)?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let summary = hit.work {
                let work = state.work(byID: String(summary.id)) ?? AppState.workFromSummary(summary)
                WorkCardView(
                    work: work,
                    blurExplicit: state.hideExplicit && work.rating == .explicit,
                    isRemoved: state.goneWorkIDs.contains(work.id),
                    onTap: { nav.openWork(work.id) }
                )
                .contextMenu {
                    WorkRowMenu(work: work, onNewReadingList: onNewReadingList,
                                onExportEpub: onExportEpub)
                }
            } else if let series = hit.series {
                seriesCard(series)
            }

            if hit.mystery && !hit.mysteryCollectionTitle.isEmpty {
                Text("Part of \(hit.mysteryCollectionTitle) — not yet revealed")
                    .font(Typography.uiCaption())
                    .foregroundStyle(theme.ink3)
            }

            bookmarkerLine
        }
    }

    @ViewBuilder
    private var bookmarkerLine: some View {
        let hasMeta = hit.rec || !hit.note.isEmpty || !hit.tags.isEmpty || !hit.dateBookmarked.isEmpty
        if hasMeta {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    Image(systemName: hit.rec ? "hand.thumbsup.fill" : "bookmark")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(hit.rec ? theme.accent : theme.ink3)
                    Text(hit.rec ? "Recommended" : "Bookmarked")
                        .font(Typography.uiSmall())
                        .foregroundStyle(theme.ink2)
                    if !hit.dateBookmarked.isEmpty {
                        Text("· \(hit.dateBookmarked)")
                            .font(Typography.uiSmall())
                            .foregroundStyle(theme.ink3)
                    }
                }
                if !hit.note.isEmpty {
                    Text(hit.note)
                        .font(Typography.summaryBody())
                        .foregroundStyle(theme.ink2)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if !hit.tags.isEmpty {
                    FlowLayout(spacing: 6) {
                        ForEach(hit.tags, id: \.self) { tag in
                            Text(tag)
                                .font(Typography.uiSmall())
                                .foregroundStyle(theme.ink2)
                                .lineLimit(1)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 3)
                                .background(Capsule().fill(theme.surface2))
                        }
                    }
                }
            }
            .padding(.horizontal, 4)
        }
    }

    private func seriesCard(_ series: USeriesSummary) -> some View {
        Button {
            nav.openSubscriptionWorks(id: String(series.id), name: series.name, subType: "series")
        } label: {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    Image(systemName: "books.vertical")
                        .font(.system(size: 11, weight: .semibold))
                    Text("SERIES")
                        .font(.custom("HankenGrotesk", size: 11.5).weight(.semibold))
                        .tracking(0.5)
                }
                .foregroundStyle(theme.ink3)

                Text(series.name)
                    .font(Typography.workTitle())
                    .foregroundStyle(theme.ink)
                    .multilineTextAlignment(.leading)
                    .lineLimit(2)

                if !series.authors.isEmpty {
                    Text("by \(series.authors.joined(separator: ", "))")
                        .font(Typography.uiCaption())
                        .foregroundStyle(theme.accent)
                }

                if !series.summary.isEmpty {
                    Text(series.summary)
                        .font(Typography.summaryBody())
                        .foregroundStyle(theme.ink2)
                        .multilineTextAlignment(.leading)
                        .lineLimit(3)
                }

                Text(seriesStats(series))
                    .font(Typography.uiCaption())
                    .foregroundStyle(theme.ink3)
            }
            .padding(theme.cardPad)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(theme.surface)
            .clipShape(RoundedRectangle(cornerRadius: Radius.card))
            .overlay(
                RoundedRectangle(cornerRadius: Radius.card)
                    .stroke(theme.line, lineWidth: 1)
            )
        }
        .buttonStyle(CardPressStyle())
    }

    private func seriesStats(_ series: USeriesSummary) -> String {
        var parts: [String] = []
        parts.append(series.workCount == 1 ? "1 work" : "\(series.workCount) works")
        parts.append("\(Int(series.wordCount).abbreviated) words")
        parts.append(series.complete ? "Complete" : "In progress")
        if !series.dateUpdated.isEmpty { parts.append("Updated \(series.dateUpdated)") }
        return parts.joined(separator: " · ")
    }
}
