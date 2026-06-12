import SwiftUI

struct TagBrowseView: View {
    @Environment(AppTheme.self) private var theme
    @Environment(AppState.self) private var state
    @Environment(NavigationState.self) private var nav

    let tag: String

    @State private var results: [Work] = []
    @State private var isLoading = false
    @State private var error: String?
    @State private var currentPage: UInt32 = 0
    @State private var tagTask = NetworkTask()

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: theme.rowGap) {
                Text(tag)
                    .font(Typography.browseTitle())
                    .foregroundStyle(theme.ink)
                    .padding(.horizontal, theme.pad)
                    .padding(.top, 8)

                if isLoading && results.isEmpty {
                    NetworkLoadingView(message: "Loading works…", task: tagTask, operation: "tag_browse") {
                        tagTask.cancel()
                        isLoading = false
                    }
                } else if let error, results.isEmpty {
                    NetworkErrorView(message: error, onRetry: {
                        self.error = nil
                        Task { await loadMore() }
                    })
                } else if results.isEmpty && !isLoading {
                    EmptyStateView(
                        systemImage: "tag",
                        title: "No works found",
                        subtitle: "No works tagged with \"\(tag)\"."
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

                        if !isLoading {
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
                            NetworkLoadingView(message: "Loading more…", task: tagTask, operation: "tag_browse") {
                                tagTask.cancel()
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
                await loadInitial()
            }
        }
    }

    private var cacheKey: String { "tag_\(tag)" }

    private func loadInitial() async {
        if let cached = state.bridge.getSessionCache(key: cacheKey, sessionId: state.sessionId),
           let works = AppState.decodeWorks(cached) {
            results = works
            currentPage = UInt32(max(1, works.count / 20))
            for w in works { state.fetchedWorks[w.id] = w }
            return
        }
        await loadMore()
    }

    private func loadMore() async {
        guard !isLoading else { return }
        isLoading = true
        error = nil
        let page = currentPage + 1
        do {
            let works = try await state.retryOnTimeout(task: tagTask, using: state.bridge) {
                try await self.state.bridge.searchByTag(tag, page: page)
            }
            let newWorks = works.map(AppState.workFromSummary)
            let existingIDs = Set(results.map(\.id))
            let unique = newWorks.filter { !existingIDs.contains($0.id) }
            if !unique.isEmpty {
                results.append(contentsOf: unique)
                for w in unique { state.fetchedWorks[w.id] = w }
            }
            currentPage = page
            if let json = AppState.encodeWorks(results) {
                state.bridge.setSessionCache(key: cacheKey, data: json, sessionId: state.sessionId)
            }
        } catch {
            if !tagTask.isCancelled && !"\(error)".contains("cancelled") {
                self.error = error.localizedDescription
            }
        }
        isLoading = false
    }
}
