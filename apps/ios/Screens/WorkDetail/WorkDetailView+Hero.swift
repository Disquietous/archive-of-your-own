import SwiftUI

extension WorkDetailView {
    // MARK: - Hero Section

    func heroSection(_ work: Work) -> some View {
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

    /// "by Author" opens the profile; the bell is the author's
    /// Followed / Subscribed menu.
    func bylineRow(_ work: Work) -> some View {
        let canOpen = isReal && !work.author.isEmpty
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
                FollowBellMenu(target: .author(work.author), weight: .medium)
            }
        }
    }

    var kudosFailureBanner: some View {
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
    /// drill-in, which crawls the series on refresh); the bell is the
    /// series' Followed / Subscribed menu.
    func seriesLine(_ s: SeriesInfo) -> some View {
        let canOpen = !s.seriesID.isEmpty && UInt64(s.seriesID) != nil
        return HStack(spacing: 4) {
            seriesLink(s, canOpen: canOpen)
            if canOpen {
                FollowBellMenu(target: FollowModel.Target(kind: .series, id: s.seriesID, name: s.name),
                               glyphSize: 11, weight: .medium, hitSize: 24)
            }
        }
    }

    func seriesLink(_ s: SeriesInfo, canOpen: Bool) -> some View {
        let label = s.part > 0 ? "Part \(s.part) of \(s.name)" : "Part of \(s.name)"
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

    func metaPills(_ work: Work) -> some View {
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

    func ratingPill(_ rating: Rating) -> some View {
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

    func warningPill(_ warnings: String) -> some View {
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

    func statusPill(_ complete: Bool) -> some View {
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

    func textPill(_ label: String, icon: String? = nil, fg: Color, bg: Color? = nil) -> some View {
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

    func statsSection(_ work: Work) -> some View {
        StatGridView(stats: [
            ("Words", work.words.abbreviated),
            ("Chapters", "\(work.chapterCount)/\(work.complete ? String(work.totalChapters) : "?")"),
            ("Kudos", work.kudos.abbreviated),
            ("Saved", work.bookmarks.abbreviated),
        ])
    }

    // MARK: - Summary

    @ViewBuilder
    func summarySection(_ work: Work) -> some View {
        if !work.summary.isEmpty {
            SummaryBoxView(summary: work.summary)
        }
    }

    // MARK: - Tags

    func tagFlow(_ work: Work) -> some View {
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
}
