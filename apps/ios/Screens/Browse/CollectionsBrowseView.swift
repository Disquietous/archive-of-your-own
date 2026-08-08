import SwiftUI

/// Paged list of AO3 collections from the /collections index — a discovery
/// surface, so results are never session-cached. Tapping a collection pushes
/// its works list.
struct CollectionsBrowseView: View {
    @Environment(AppTheme.self) private var theme
    @Environment(AppState.self) private var state
    @Environment(NavigationState.self) private var nav

    @State private var collections: [UCollection] = []
    @State private var isLoading = false
    @State private var error: String?
    @State private var currentPage: UInt32 = 0
    @State private var hasMore = true
    @State private var collectionsTask = NetworkTask()

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: theme.rowGap) {
                Text("Collections")
                    .font(Typography.browseTitle())
                    .foregroundStyle(theme.ink)
                    .padding(.horizontal, theme.pad)
                    .padding(.top, 8)

                if isLoading && collections.isEmpty {
                    NetworkLoadingView(message: "Loading collections…", task: collectionsTask, operation: "collections_browse") {
                        collectionsTask.cancel()
                        isLoading = false
                    }
                } else if let error, collections.isEmpty {
                    NetworkErrorView(message: error, onRetry: {
                        self.error = nil
                        Task { await loadMore() }
                    })
                } else if collections.isEmpty && !isLoading {
                    EmptyStateView(
                        systemImage: "square.grid.2x2",
                        title: "No collections",
                        subtitle: "Collections from the archive appear here."
                    )
                    .padding(.top, 40)
                } else {
                    LazyVStack(spacing: theme.rowGap) {
                        ForEach(collections, id: \.name) { collection in
                            CollectionCardView(collection: collection) {
                                nav.openCollection(name: collection.name,
                                                   title: collection.title.isEmpty ? collection.name : collection.title)
                            }
                            .onAppear {
                                // Infinite scroll: reaching the last row loads
                                // the next page while AO3 says there is one.
                                if collection.name == collections.last?.name && hasMore && !isLoading {
                                    Task { await loadMore() }
                                }
                            }
                        }

                        if isLoading {
                            NetworkLoadingView(message: "Loading more…", task: collectionsTask, operation: "collections_browse") {
                                collectionsTask.cancel()
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
            if collections.isEmpty {
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
            let result = try await state.retryOnTimeout(task: collectionsTask, using: state.bridge) {
                try await self.state.bridge.browseCollections(page: page)
            }
            let existingNames = Set(collections.map(\.name))
            collections.append(contentsOf: result.collections.filter { !existingNames.contains($0.name) })
            currentPage = page
            hasMore = result.hasNextPage
        } catch {
            if !collectionsTask.isCancelled && !error.isCancellation {
                self.error = error.localizedDescription
            }
        }
        isLoading = false
    }
}

/// One collection blurb: title, status/type line, counts, short summary.
private struct CollectionCardView: View {
    @Environment(AppTheme.self) private var theme

    let collection: UCollection
    var onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            VStack(alignment: .leading, spacing: 6) {
                Text(collection.title.isEmpty ? collection.name : collection.title)
                    .font(Typography.workTitle())
                    .foregroundStyle(theme.ink)
                    .multilineTextAlignment(.leading)
                    .lineLimit(2)

                Text(statusLine)
                    .font(Typography.uiSmall())
                    .foregroundStyle(theme.ink3)

                Text(countsLine)
                    .font(Typography.uiCaption())
                    .foregroundStyle(theme.ink2)

                if !collection.summary.isEmpty {
                    Text(collection.summary)
                        .font(Typography.summaryBody())
                        .foregroundStyle(theme.ink2)
                        .multilineTextAlignment(.leading)
                        .lineLimit(2)
                }
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

    private var statusLine: String {
        var parts: [String] = [collection.isOpen ? "Open" : "Closed"]
        if collection.isModerated { parts.append("Moderated") }
        if collection.isAnonymous { parts.append("Anonymous") }
        if !collection.collectionType.isEmpty { parts.append(collection.collectionType) }
        return parts.joined(separator: " · ")
    }

    private var countsLine: String {
        let works = collection.workCount == 1 ? "1 work" : "\(collection.workCount) works"
        let bookmarks = collection.bookmarkedCount == 1
            ? "1 bookmarked item" : "\(collection.bookmarkedCount) bookmarked items"
        return "\(works) · \(bookmarks)"
    }
}
