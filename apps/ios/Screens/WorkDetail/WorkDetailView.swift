import SwiftUI

struct WorkDetailView: View {
    @Environment(AppTheme.self) var theme
    @Environment(AppState.self) var state
    @Environment(NavigationState.self) var nav
    @Environment(FollowModel.self) var follows
    @Environment(\.openWindow) var openWindow

    let workID: String

    @State var exportedEpub: EpubExporter.Exported?
    @State var exportError: String?

    var work: Work? {
        state.work(byID: workID)
    }

    var progress: ReadingProgress? {
        state.progressMap[workID]
    }

    var isBookmarked: Bool {
        state.bookmarkedWorkIDs.contains(workID)
    }

    var isDownloaded: Bool {
        state.downloadedWorkIDs.contains(workID)
    }

    var isFinished: Bool {
        state.finishedWorkIDs.contains(workID)
    }

    var hasKudos: Bool {
        state.kudosGivenWorkIDs.contains(workID)
    }

    var kudosPending: Bool {
        state.kudosPendingWorkIDs.contains(workID)
    }

    var isReal: Bool { UInt64(workID) != nil }

    var isLiveWork: Bool {
        isReal && work?.content == nil
    }

    var ao3URL: URL? {
        isReal ? ExternalLinkOpener.ao3WorkURL(workID) : nil
    }

    /// The detail screen's tracked operations — refresh and kudos both post
    /// from here, so either one's requests show in the banner.
    var bannerOpID: UInt64? {
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

    var pendingRemovalBinding: Binding<Bool> {
        Binding(get: { state.pendingBookmarkRemoval == workID },
                set: { if !$0 { state.cancelBookmarkRemoval() } })
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
