import SwiftUI

/// Paged works list for one collection — the tag-browse pattern backed by
/// fetchCollectionWorks. Works land in the Rust works cache as they arrive;
/// the listing itself is a discovery surface and is not session-cached.
struct CollectionWorksView: View {
    @Environment(AppTheme.self) private var theme
    @Environment(AppState.self) private var state
    @Environment(NavigationState.self) private var nav

    /// URL slug from UCollection.name.
    let name: String
    let title: String

    @State private var results: [Work] = []
    @State private var isLoading = false
    @State private var error: String?
    @State private var currentPage: UInt32 = 0
    @State private var hasMore = true
    @State private var worksTask = NetworkTask()

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: theme.rowGap) {
                Text(title)
                    .font(Typography.browseTitle())
                    .foregroundStyle(theme.ink)
                    .padding(.horizontal, theme.pad)
                    .padding(.top, 8)

                if isLoading && results.isEmpty {
                    NetworkLoadingView(message: "Loading works…", task: worksTask, operation: "collection_works") {
                        worksTask.cancel()
                        isLoading = false
                    }
                } else if let error, results.isEmpty {
                    NetworkErrorView(message: error, onRetry: {
                        self.error = nil
                        Task { await loadMore() }
                    })
                } else if results.isEmpty && !isLoading {
                    EmptyStateView(
                        systemImage: "square.grid.2x2",
                        title: "No works found",
                        subtitle: "No works in \"\(title)\"."
                    )
                    .padding(.top, 40)
                } else {
                    LazyVStack(spacing: theme.rowGap) {
                        ForEach(results) { work in
                            WorkCardView(
                                work: work,
                                blurExplicit: state.hideExplicit && work.rating == .explicit,
                                onTap: { nav.openWork(work.id) }
                            )
                        }

                        if !isLoading && hasMore {
                            Button {
                                Task { await loadMore() }
                            } label: {
                                Text("Load more")
                                    .font(Typography.smallButtonLabel())
                                    .foregroundStyle(theme.accent)
                                    .frame(maxWidth: .infinity)
                                    .frame(height: 44)
                                    .background(
                                        RoundedRectangle(cornerRadius: Radius.button)
                                            .stroke(theme.line, lineWidth: 1)
                                    )
                            }
                            .buttonStyle(ButtonPressStyle())
                        }

                        if isLoading {
                            NetworkLoadingView(message: "Loading more…", task: worksTask, operation: "collection_works") {
                                worksTask.cancel()
                                isLoading = false
                            }
                        }
                    }
                    .padding(.horizontal, theme.pad)
                }
            }
            .padding(.bottom, 32)
        }
        .background(theme.bg)
        .navigationBarBackButtonHidden(true)
        .toolbar(.hidden, for: .tabBar)
        .toolbar {
            ToolbarItem(placement: .navigationBarLeading) {
                Button { nav.goBack() } label: {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(theme.ink)
                }
            }
        }
        .task {
            if results.isEmpty {
                await loadMore()
            }
        }
    }

    private func loadMore() async {
        guard !isLoading else { return }
        isLoading = true
        error = nil
        let page = currentPage + 1
        do {
            let result = try await state.retryOnTimeout(task: worksTask, using: state.bridge) {
                try await self.state.bridge.fetchCollectionWorks(name: self.name, page: page)
            }
            let newWorks = result.works.map(AppState.workFromSummary)
            let existingIDs = Set(results.map(\.id))
            let unique = newWorks.filter { !existingIDs.contains($0.id) }
            if !unique.isEmpty {
                results.append(contentsOf: unique)
                for w in unique { state.fetchedWorks[w.id] = w }
            }
            currentPage = page
            hasMore = result.hasNextPage
        } catch {
            if !worksTask.isCancelled && !error.isCancellation {
                self.error = error.localizedDescription
            }
        }
        isLoading = false
    }
}
