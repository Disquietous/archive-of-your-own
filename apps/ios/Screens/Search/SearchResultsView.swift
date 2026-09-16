import SwiftUI

/// The Search tab's results state, driven by the shared `SearchModel`:
/// works-style results (the Works form, a tag, a collection's works) in a
/// work-card list; bookmark hits as bookmark cards; tag / user /
/// collection hits as navigating rows; and the split collection view
/// (works | bookmarked items). Pagination and the request banner follow
/// the model's active query.
struct SearchResultsView: View {
    @Environment(AppTheme.self) private var theme
    @Environment(AppState.self) private var state
    @Environment(NavigationState.self) private var nav
    @Environment(SearchModel.self) private var search
    @Environment(LibraryListModel.self) private var lists
    @Environment(FollowModel.self) private var follows

    @State private var newListFor: Work?
    @State private var newListName = ""
    @State private var exportedEpub: EpubExporter.Exported?
    @State private var exportError: String?

    /// The works results through the shared list model — section prefs
    /// (sort / completion / rating) and the session list filter.
    private var works: [Work] {
        lists.works(for: .search, raw: state.searchResults)
    }

    private var worksStyle: Bool { search.scope == .works }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: theme.rowGap) {
                if search.splitCollectionName != nil {
                    CollectionSplitView(newListFor: $newListFor, exportEpub: exportEpub)
                } else if worksStyle {
                    worksResults
                } else {
                    scopeResults
                }
            }
            .padding(.horizontal, theme.pad)
            .padding(.bottom, 32)
        }
        .sheet(item: $exportedEpub) { exported in
            ShareSheet(items: [exported.url])
                .presentationDetents([.medium, .large])
        }
        .alert("Couldn’t export EPUB", isPresented: Binding(
            get: { exportError != nil },
            set: { if !$0 { exportError = nil } })) {
            Button("OK", role: .cancel) { exportError = nil }
        } message: {
            Text(exportError ?? "")
        }
        .alert("New Reading List", isPresented: Binding(
            get: { newListFor != nil },
            set: { if !$0 { newListFor = nil; newListName = "" } })) {
            TextField("List name", text: $newListName)
            Button("Create") {
                let name = newListName.trimmingCharacters(in: .whitespaces)
                if let work = newListFor, !name.isEmpty {
                    let listId = state.createReadingList(name)
                    if listId >= 0 { state.addToReadingList(listId, workId: work.id) }
                }
                newListFor = nil
                newListName = ""
            }
            Button("Cancel", role: .cancel) { newListFor = nil; newListName = "" }
        } message: {
            if let work = newListFor {
                Text("“\(work.title)” will be added to the new list.")
            }
        }
    }

    private func exportEpub(_ work: Work) {
        do {
            exportedEpub = try EpubExporter.export(work: work, appState: state)
        } catch {
            exportError = error.localizedDescription
        }
    }

    // MARK: - Works-style results

    @ViewBuilder
    private var worksResults: some View {
        let works = works
        let filterActive = lists.workListFilter(for: .search).isActive
        if state.isSearching && works.isEmpty {
            searchingView
        } else if let error = state.searchError, works.isEmpty {
            NetworkErrorView(message: error, onRetry: { rerun() })
        } else if works.isEmpty {
            if filterActive && !state.searchResults.isEmpty {
                filteredOutView { lists.workListFilters[.search] = nil }
            } else {
                EmptyStateView(systemImage: "magnifyingglass",
                               title: search.searchLibraryOnly && search.activeQuery == nil
                                   ? "No matches in your library" : "No works found",
                               subtitle: emptyWorksSubtitle)
                    .padding(.top, 40)
            }
        } else {
            pager
            LazyVStack(spacing: theme.rowGap) {
                ForEach(works) { work in
                    WorkCardView(
                        work: work,
                        blurExplicit: state.hideExplicit && work.rating == .explicit,
                        isRemoved: state.goneWorkIDs.contains(work.id),
                        onAuthorTap: UInt64(work.id) != nil ? {
                            nav.searchPath.append(AppDestination.authorWorks(
                                username: AppState.canonicalAuthorUsername(work.author)))
                        } : nil,
                        onTap: { nav.openWork(work.id) }
                    )
                    .contextMenu {
                        WorkRowMenu(work: work, onNewReadingList: { newListFor = $0 },
                                    onExportEpub: { exportEpub($0) })
                    }
                }
            }
            if state.isSearching {
                statusLine("Loading page…")
            }
            pager
        }
    }

    private var emptyWorksSubtitle: String {
        if search.searchLibraryOnly && search.activeQuery == nil {
            return "Only what the app has already cached is searched. Browse or fetch more to grow the library."
        }
        return search.currentPage > 1
            ? "No results on page \(search.currentPage) — try an earlier page."
            : "Try different terms or fewer filters."
    }

    /// Re-run whatever produced the current results after a failure.
    private func rerun() {
        state.searchError = nil
        if search.activeQuery != nil {
            search.goToPage(search.currentPage, appState: state)
        } else if search.scope == .works, search.activeWorksRequest != nil {
            search.runWorksSearch(search.activeWorksRequest!, appState: state)
        } else {
            search.performScopedSearch(state)
        }
    }

    // MARK: - Scope results (tags / users / collections / bookmarks)

    @ViewBuilder
    private var scopeResults: some View {
        switch search.scope {
        case .bookmarks:
            bookmarkResults
        case .tags:
            if state.isSearching && search.tagHits.isEmpty {
                searchingView
            } else if search.tagHits.isEmpty {
                scopeEmptyState
            } else {
                LazyVStack(spacing: 0) {
                    ForEach(Array(search.tagHits.enumerated()), id: \.offset) { _, hit in
                        hitRow(icon: "tag", title: hit.name, sub: Self.tagTypeLabel(hit.tagType)) {
                            search.startTagQuery(hit.name, appState: state)
                        }
                    }
                }
                .background(theme.surface)
                .clipShape(RoundedRectangle(cornerRadius: Radius.card))
                .overlay(RoundedRectangle(cornerRadius: Radius.card).stroke(theme.line, lineWidth: 1))
            }
        case .users:
            if state.isSearching && search.userHits.isEmpty {
                searchingView
            } else if search.userHits.isEmpty {
                scopeEmptyState
            } else {
                LazyVStack(spacing: 0) {
                    ForEach(search.userHits, id: \.self) { username in
                        userRow(username)
                    }
                }
                .background(theme.surface)
                .clipShape(RoundedRectangle(cornerRadius: Radius.card))
                .overlay(RoundedRectangle(cornerRadius: Radius.card).stroke(theme.line, lineWidth: 1))
            }
        case .collections:
            if state.isSearching && search.collectionHits.isEmpty {
                searchingView
            } else if let error = state.searchError, search.collectionHits.isEmpty {
                NetworkErrorView(message: error, onRetry: { rerun() })
            } else if search.collectionHits.isEmpty {
                scopeEmptyState
            } else {
                if case .collectionsIndex = search.activeQuery { pager }
                LazyVStack(spacing: theme.rowGap) {
                    ForEach(search.collectionHits, id: \.name) { collection in
                        CollectionCardView(collection: collection) {
                            search.startCollectionQuery(collection.name,
                                                        title: collection.title,
                                                        workCount: collection.workCount,
                                                        bookmarkedCount: collection.bookmarkedCount,
                                                        fromHitList: true,
                                                        appState: state)
                        }
                    }
                }
                if case .collectionsIndex = search.activeQuery { pager }
            }
        case .works:
            EmptyView()
        }
    }

    @ViewBuilder
    private var bookmarkResults: some View {
        let hits = search.filteredBookmarkHits
        if state.isSearching && hits.isEmpty {
            searchingView
        } else if let error = state.searchError, hits.isEmpty {
            NetworkErrorView(message: error, onRetry: { rerun() })
        } else if hits.isEmpty {
            if search.bookmarkListFilter.isActive && !search.bookmarkHits.isEmpty {
                filteredOutView { search.bookmarkListFilter = SearchModel.BookmarkListFilter() }
            } else {
                scopeEmptyState
            }
        } else {
            if case .bookmarkSearch = search.activeQuery { pager }
            LazyVStack(spacing: theme.rowGap) {
                ForEach(hits, id: \.self) { hit in
                    BookmarkHitCard(hit: hit, onNewReadingList: { newListFor = $0 },
                                    onExportEpub: { exportEpub($0) })
                }
            }
            if case .bookmarkSearch = search.activeQuery { pager }
        }
    }

    // MARK: - Shared pieces

    /// Numbered pages for the AO3-side queries; library reads return
    /// everything at once (activeQuery nil), so the pager stays out.
    @ViewBuilder
    private var pager: some View {
        if search.activeQuery != nil, search.hasSearched,
           search.totalPages > 1 || search.hasNextPage || search.currentPage > 1 {
            PagerControl(current: Int(search.currentPage),
                         total: Int(search.totalPages),
                         hasNext: search.hasNextPage,
                         busy: state.isSearching) { page in
                search.goToPage(page, appState: state)
            }
        }
    }

    private var searchingView: some View {
        NetworkLoadingView(message: search.searchLibraryOnly ? "Searching your library…"
                                                              : "Searching the archive…",
                           task: state.searchTask) {
            cancelSearch()
        }
    }

    private func cancelSearch() {
        state.searchTask.cancel()
        if let opID = search.searchFetchOp.opID { state.bridge.cancelOperation(opID) }
    }

    private var scopeEmptyState: some View {
        EmptyStateView(
            systemImage: "magnifyingglass",
            title: search.searchLibraryOnly ? "No matches in your library" : "No matches on AO3",
            subtitle: search.searchLibraryOnly
                ? "Only what the app has already cached is searched. Browse or fetch more to grow the library."
                : "Nothing on AO3 matched these criteria.")
            .padding(.top, 40)
    }

    private func filteredOutView(clear: @escaping () -> Void) -> some View {
        VStack(spacing: 12) {
            EmptyStateView(systemImage: "line.3.horizontal.decrease.circle",
                           title: "Nothing matches the filter",
                           subtitle: "Adjust or clear the list filter to see the results again.")
            Button("Clear Filter", action: clear)
                .font(Typography.smallButtonLabel())
                .foregroundStyle(theme.accent)
                .buttonStyle(ButtonPressStyle())
        }
        .padding(.top, 40)
    }

    private func statusLine(_ text: String) -> some View {
        HStack(spacing: 8) {
            ProgressView().controlSize(.small).tint(theme.ink3)
            Text(text)
                .font(.custom("HankenGrotesk", size: 12).weight(.medium))
                .foregroundStyle(theme.ink3)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 8)
    }

    static func tagTypeLabel(_ tagType: String) -> String {
        switch tagType {
        case "fandom": "Fandom"
        case "character": "Character"
        case "relationship": "Relationship"
        case "freeform": "Additional tag"
        case "creator": "Creator"
        default: tagType.capitalized
        }
    }

    /// A user hit — the generic row plus the local follow bell.
    private func userRow(_ username: String) -> some View {
        let followState = follows.authorFollowState(username)
        return Button {
            nav.searchPath.append(AppDestination.authorWorks(
                username: AppState.canonicalAuthorUsername(username)))
        } label: {
            HStack(spacing: 12) {
                Image(systemName: "person")
                    .font(.system(size: 14, weight: .medium))
                    .frame(width: 20)
                    .foregroundStyle(theme.accent)
                VStack(alignment: .leading, spacing: 1) {
                    Text(username)
                        .font(Typography.uiBody())
                        .foregroundStyle(theme.ink)
                        .lineLimit(1)
                    Text("AO3 user")
                        .font(Typography.uiSmall())
                        .foregroundStyle(theme.ink3)
                }
                Spacer()
                Button {
                    follows.toggleAuthorFollow(username)
                } label: {
                    Image(systemName: followState == .none ? "bell" : "bell.fill")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(followState == .none ? theme.ink3 : theme.accent)
                        .frame(width: 32, height: 32)
                        .contentShape(Rectangle())
                }
                .buttonStyle(IconButtonPressStyle())
                Image(systemName: "chevron.right")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(theme.ink3)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .overlay(alignment: .bottom) { theme.line.frame(height: 1) }
    }

    private func hitRow(icon: String, title: String, sub: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: icon)
                    .font(.system(size: 14, weight: .medium))
                    .frame(width: 20)
                    .foregroundStyle(theme.accent)
                VStack(alignment: .leading, spacing: 1) {
                    Text(title)
                        .font(Typography.uiBody())
                        .foregroundStyle(theme.ink)
                        .lineLimit(2)
                    Text(sub)
                        .font(Typography.uiSmall())
                        .foregroundStyle(theme.ink3)
                }
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(theme.ink3)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .overlay(alignment: .bottom) { theme.line.frame(height: 1) }
    }
}

/// The split collection view: a works listing and a bookmarked-items
/// listing, independently paged — stacked on a phone, side by side in
/// regular width (D4).
struct CollectionSplitView: View {
    @Environment(AppTheme.self) private var theme
    @Environment(AppState.self) private var state
    @Environment(NavigationState.self) private var nav
    @Environment(SearchModel.self) private var search
    @Environment(LibraryListModel.self) private var lists
    @Environment(\.horizontalSizeClass) private var sizeClass

    @Binding var newListFor: Work?
    let exportEpub: (Work) -> Void

    var body: some View {
        if sizeClass == .regular {
            HStack(alignment: .top, spacing: theme.pad) {
                worksHalf.frame(maxWidth: .infinity, alignment: .topLeading)
                bookmarksHalf.frame(maxWidth: .infinity, alignment: .topLeading)
            }
        } else {
            worksHalf
            bookmarksHalf
        }
    }

    private var worksHalf: some View {
        VStack(alignment: .leading, spacing: theme.rowGap) {
            halfHeader("WORKS", total: search.totalWorks)
            if let opID = search.searchFetchOp.opID {
                RequestProgressBanner(opID: opID) {
                    state.bridge.cancelOperation(opID)
                }
            }
            let works = lists.works(for: .search, raw: state.searchResults)
            if state.isSearching && works.isEmpty {
                loadingLine("Fetching works…")
            } else if let error = state.searchError, works.isEmpty {
                NetworkErrorView(message: error, onRetry: {
                    search.goToPage(search.currentPage, appState: state)
                })
            } else if works.isEmpty {
                EmptyStateView(systemImage: "doc.text", title: "No works",
                               subtitle: "This collection’s works listing is empty.")
                    .padding(.vertical, 20)
            } else {
                PagerControl(current: Int(search.currentPage), total: Int(search.totalPages),
                             hasNext: search.hasNextPage, busy: state.isSearching) { page in
                    search.goToPage(page, appState: state)
                }
                LazyVStack(spacing: theme.rowGap) {
                    ForEach(works) { work in
                        card(work)
                    }
                }
            }
        }
    }

    private var bookmarksHalf: some View {
        VStack(alignment: .leading, spacing: theme.rowGap) {
            halfHeader("BOOKMARKED ITEMS", total: search.bookmarksTotal)
            if let opID = search.bookmarksFetchOp.opID {
                RequestProgressBanner(opID: opID) {
                    state.bridge.cancelOperation(opID)
                }
            }
            let works = search.bookmarkResults
            if search.isFetchingBookmarks && works.isEmpty {
                loadingLine("Fetching bookmarked items…")
            } else if let error = search.bookmarksError, works.isEmpty {
                NetworkErrorView(message: error, onRetry: {
                    search.goToBookmarksPage(search.bookmarksPage, appState: state)
                })
            } else if works.isEmpty {
                EmptyStateView(systemImage: "bookmark", title: "No bookmarked works",
                               subtitle: "This collection’s bookmarked items include no works the app can show.")
                    .padding(.vertical, 20)
            } else {
                PagerControl(current: Int(search.bookmarksPage), total: Int(search.bookmarksTotalPages),
                             hasNext: search.bookmarksHasNext, busy: search.isFetchingBookmarks) { page in
                    search.goToBookmarksPage(page, appState: state)
                }
                LazyVStack(spacing: theme.rowGap) {
                    ForEach(works) { work in
                        card(work)
                    }
                }
            }
        }
    }

    private func card(_ work: Work) -> some View {
        WorkCardView(
            work: work,
            blurExplicit: state.hideExplicit && work.rating == .explicit,
            isRemoved: state.goneWorkIDs.contains(work.id),
            onAuthorTap: UInt64(work.id) != nil ? {
                nav.searchPath.append(AppDestination.authorWorks(
                    username: AppState.canonicalAuthorUsername(work.author)))
            } : nil,
            onTap: { nav.openWork(work.id) }
        )
        .contextMenu {
            WorkRowMenu(work: work, onNewReadingList: { newListFor = $0 },
                        onExportEpub: exportEpub)
        }
    }

    private func halfHeader(_ title: String, total: UInt32?) -> some View {
        HStack(spacing: 8) {
            Text(title)
                .font(Typography.sectionHeader())
                .tracking(0.08 * 13)
                .foregroundStyle(theme.ink3)
            if let total {
                Text("\(total)")
                    .font(Typography.uiSmall())
                    .foregroundStyle(theme.ink3)
            }
            Spacer()
        }
        .padding(.top, 8)
    }

    private func loadingLine(_ text: String) -> some View {
        HStack(spacing: 8) {
            ProgressView().controlSize(.small).tint(theme.ink3)
            Text(text)
                .font(.custom("HankenGrotesk", size: 12).weight(.medium))
                .foregroundStyle(theme.ink3)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 16)
    }
}
