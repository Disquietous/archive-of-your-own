import SwiftUI

extension WorkDetailView {
    // MARK: - Engagement Row

    func engagementRow(_ work: Work) -> some View {
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

    var currentChapterSelection: Int {
        progress?.chapter ?? 1
    }

    func chaptersSection(_ work: Work) -> some View {
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
    func chapterTitle(_ num: Int, work: Work) -> String {
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

    func bottomBar(_ work: Work) -> some View {
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

    var primaryButtonLabel: String {
        if let p = progress, p.pos > 0 || p.chapter > 1 {
            return "Continue \u{00B7} Ch. \(p.chapter)"
        }
        return "Start reading"
    }
}
