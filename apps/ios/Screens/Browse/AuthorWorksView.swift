import SwiftUI

struct AuthorWorksView: View {
    @Environment(AppTheme.self) private var theme
    @Environment(AppState.self) private var state
    @Environment(NavigationState.self) private var nav
    @Environment(\.dismiss) private var dismiss

    let username: String

    @State private var results: [Work] = []
    @State private var isLoading = false
    @State private var error: String?
    @State private var currentPage: UInt32 = 0
    @State private var hasMore = true
    @State private var authorTask = NetworkTask()

    private var cacheKey: String { "author_works_\(username)" }

    var body: some View {
        ZStack(alignment: .top) {
            ScrollView {
                VStack(alignment: .leading, spacing: theme.rowGap) {
                    Spacer()
                        .frame(height: 56)

                    if isLoading && results.isEmpty {
                        NetworkLoadingView(message: "Loading works...", task: authorTask, operation: "author_works") {
                            authorTask.cancel()
                            isLoading = false
                        }
                    } else if let error, results.isEmpty {
                        NetworkErrorView(message: error, onRetry: {
                            Task { await loadWorks(force: true) }
                        })
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

                            if isLoading && !results.isEmpty {
                                NetworkLoadingView(message: "Loading more...", task: authorTask, operation: "author_works") {
                                    authorTask.cancel()
                                }
                            }
                        }
                    }
                }
                .padding(.horizontal, theme.pad)
            }

            topChrome
        }
        .background(theme.bg)
        .navigationBarBackButtonHidden(true)
        .toolbar(.hidden, for: .tabBar)
        .toolbar(.hidden, for: .navigationBar)
        .task {
            if results.isEmpty {
                await loadWorks()
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

            Text(username)
                .font(Typography.uiBody())
                .foregroundStyle(theme.ink)
                .lineLimit(1)

            Spacer()

            if !results.isEmpty {
                Button {
                    Task { await loadWorks(force: true) }
                } label: {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(theme.ink2)
                        .frame(width: 36, height: 36)
                }
                .buttonStyle(IconButtonPressStyle())
                .disabled(isLoading)
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

    private func loadWorks(force: Bool = false) async {
        guard !isLoading else { return }

        if !force, let cached = loadFromCache() {
            results = cached
            currentPage = 1
            return
        }

        isLoading = true
        error = nil
        currentPage = 0
        do {
            let result = try await state.retryOnTimeout(task: authorTask, using: state.bridge) {
                try await state.bridge.fetchAuthorWorks(username: username, page: 1)
            }
            results = result.works.map(AppState.workFromSummary)
            currentPage = 1
            hasMore = result.hasNextPage
            saveToCache(results)
        } catch {
            if !authorTask.isCancelled && !"\(error)".contains("cancelled") {
                self.error = error.localizedDescription
            }
        }
        isLoading = false
    }

    private func loadMore() async {
        guard !isLoading else { return }
        isLoading = true
        let page = currentPage + 1
        do {
            let result = try await state.retryOnTimeout(task: authorTask, using: state.bridge) {
                try await state.bridge.fetchAuthorWorks(username: username, page: page)
            }
            let newWorks = result.works.map(AppState.workFromSummary)
            let existingIDs = Set(results.map(\.id))
            let unique = newWorks.filter { !existingIDs.contains($0.id) }
            results.append(contentsOf: unique)
            currentPage = page
            hasMore = result.hasNextPage
            saveToCache(results)
        } catch {
            if !authorTask.isCancelled && !"\(error)".contains("cancelled") {
                self.error = error.localizedDescription
            }
        }
        isLoading = false
    }

    private func saveToCache(_ works: [Work]) {
        if let json = AppState.encodeWorks(works) {
            state.bridge.setSessionCache(key: cacheKey, data: json, sessionId: state.sessionId)
        }
    }

    private func loadFromCache() -> [Work]? {
        guard let json = state.bridge.getSessionCache(key: cacheKey, sessionId: state.sessionId) else { return nil }
        return AppState.decodeWorks(json)
    }
}
