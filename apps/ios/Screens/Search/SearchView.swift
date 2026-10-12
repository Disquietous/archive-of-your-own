import SwiftUI

/// The Search tab, driven by the shared `SearchModel`: a wrapping scope
/// control (Works / Collections / Bookmarks / Tags / Users), a Library |
/// AO3 source control, the scope's criteria form, and — once a query runs
/// — the results state with its back arrow, pager, list filter and
/// server-side sort. Tag pills anywhere in the app land here through
/// `NavigationState.openTag`.
struct SearchView: View {
    @Environment(AppTheme.self) var theme
    @Environment(AppState.self) var state
    @Environment(NavigationState.self) var nav
    @Environment(SearchModel.self) var search
    @Environment(LibraryListModel.self) var lists

    var initialShowFilters: Bool = false
    /// Screenshot harness only: seed the criteria fields without a library.
    var initialFormFields: [UFormField]?

    @State var showFilters = false
    @State var didApplyInitialFilters = false
    @State var showFilterSheet = false
    @State var showBookmarkFilterSheet = false

    var body: some View {
        VStack(spacing: 0) {
            header
            if search.showingResults, let opID = search.searchFetchOp.opID,
               search.splitCollectionName == nil {
                RequestProgressBanner(opID: opID) {
                    state.searchTask.cancel()
                    state.bridge.cancelOperation(opID)
                }
                .padding(.horizontal, theme.pad)
                .padding(.bottom, 8)
                .transition(.move(edge: .top).combined(with: .opacity))
            }
            if search.showingResults {
                SearchResultsView()
            } else {
                formScroll
            }
        }
        .animation(.easeInOut(duration: 0.2), value: search.searchFetchOp.opID)
        .background { ThemeBackgroundView() }
        .task {
            if !didApplyInitialFilters {
                showFilters = initialShowFilters
                didApplyInitialFilters = true
            }
            if let seeded = initialFormFields, search.formFields.isEmpty {
                search.formFields = seeded
            } else if state.bridge.isInitialized {
                await search.loadFormIfNeeded(state)
            }
            search.loadSavedSearches(state)
            consumePendingQueries()
        }
        .onChange(of: state.bridge.isInitialized) { _, initialized in
            if initialized && search.formFields.isEmpty {
                Task { await search.loadFormIfNeeded(state) }
            }
        }
        .onChange(of: nav.pendingTagQuery) { consumePendingQueries() }
        .onChange(of: nav.pendingAO3TagListing) { consumePendingQueries() }
        .sheet(isPresented: $showFilterSheet) {
            WorkListFilterSheet(section: .search,
                                availableTags: lists.availableTags(for: .search, raw: state.searchResults),
                                availableFandoms: lists.availableFandoms(for: .search, raw: state.searchResults))
                .environment(theme)
                .environment(lists)
        }
        .sheet(isPresented: $showBookmarkFilterSheet) {
            BookmarkListFilterSheet()
                .environment(theme)
                .environment(search)
        }
    }

    /// Queries handed over from other tabs (tag pills, the Fandoms
    /// drill-in's Search AO3) run the moment the tab shows them.
    func consumePendingQueries() {
        if let tag = nav.pendingTagQuery {
            nav.pendingTagQuery = nil
            search.startTagQuery(tag, appState: state)
        }
        if let tag = nav.pendingAO3TagListing {
            nav.pendingAO3TagListing = nil
            search.startAO3TagListing(tag, appState: state)
        }
    }

}

#Preview {
    SearchView()
        .environment(AppTheme())
        .environment(AppState())
        .environment(NavigationState())
}
