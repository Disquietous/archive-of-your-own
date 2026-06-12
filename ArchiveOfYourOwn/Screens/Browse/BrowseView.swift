import SwiftUI

struct BrowseView: View {
    @Environment(AppTheme.self) private var theme
    @Environment(AppState.self) private var state
    @Environment(NavigationState.self) private var nav

    @State private var sortBy: SortOption = .latest
    @State private var filterRating: RatingFilter = .all
    @State private var filterComplete: CompleteFilter = .all
    @State private var showFilters = false

    enum SortOption: String, CaseIterable {
        case latest = "Latest"
        case kudos = "Kudos"
        case hits = "Hits"
        case words = "Words"
    }

    enum RatingFilter: String, CaseIterable {
        case all = "All Ratings"
        case general = "General"
        case teen = "Teen"
        case mature = "Mature"
        case explicit = "Explicit"
    }

    enum CompleteFilter: String, CaseIterable {
        case all = "All"
        case complete = "Complete"
        case wip = "In Progress"
    }

    private var displayedWorks: [Work] {
        var results = state.browseResults

        if state.hideExplicit {
            results = results.filter { $0.rating != .explicit }
        }

        switch filterRating {
        case .all: break
        case .general: results = results.filter { $0.rating == .general }
        case .teen: results = results.filter { $0.rating == .teen }
        case .mature: results = results.filter { $0.rating == .mature }
        case .explicit: results = results.filter { $0.rating == .explicit }
        }

        switch filterComplete {
        case .all: break
        case .complete: results = results.filter { $0.complete }
        case .wip: results = results.filter { !$0.complete }
        }

        switch sortBy {
        case .latest: break
        case .kudos: results.sort { $0.kudos > $1.kudos }
        case .hits: results.sort { $0.hits > $1.hits }
        case .words: results.sort { $0.words > $1.words }
        }

        return results
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: theme.rowGap) {
                masthead
                filterBar.padding(.horizontal, theme.pad)

                if showFilters {
                    filterControls.padding(.horizontal, theme.pad)
                }

                if state.isBrowsing && displayedWorks.isEmpty {
                    NetworkLoadingView(message: "Loading works…", task: state.browseTask, operation: "browse") {
                        state.browseTask.cancel()
                    }
                } else if let error = state.searchError, state.browseResults.isEmpty {
                    NetworkErrorView(message: error, onRetry: {
                        state.searchError = nil
                        Task { await state.browseLatestWorks() }
                    })
                } else if displayedWorks.isEmpty && !state.isBrowsing {
                    EmptyStateView(
                        systemImage: "book",
                        title: "No works",
                        subtitle: filterRating != .all || filterComplete != .all
                            ? "Try changing your filters."
                            : "Check your connection and try again."
                    )
                    .padding(.top, 40)
                } else {
                    LazyVStack(spacing: theme.rowGap) {
                        ForEach(displayedWorks) { work in
                            WorkCardView(
                                work: work,
                                blurExplicit: state.hideExplicit && work.rating == .explicit,
                                onTap: { nav.openWork(work.id) }
                            )
                        }

                        if state.isBrowsing {
                            NetworkLoadingView(message: "Loading works…", task: state.browseTask, operation: "browse") {
                                state.browseTask.cancel()
                            }
                        }
                    }
                    .padding(.horizontal, theme.pad)
                }
            }
            .padding(.bottom, 32)
        }
        .background { ThemeBackgroundView() }
        .task {
            if state.browseResults.isEmpty && state.bridge.isInitialized {
                await state.browseLatestWorks()
            }
        }
        .onChange(of: state.bridge.isInitialized) { _, initialized in
            if initialized && state.browseResults.isEmpty {
                Task { await state.browseLatestWorks() }
            }
        }
    }

    private var masthead: some View {
        HStack {
            Text("Browse")
                .font(Typography.browseTitle())
                .foregroundStyle(theme.ink)
            Spacer()
            Button {
                state.bridge.invalidateSessionCache(key: "browse")
                state.browseResults = []
                state.browseCurrentPage = 0
                Task { await state.browseLatestWorks(force: true) }
            } label: {
                Image(systemName: "arrow.clockwise")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(theme.ink2)
                    .frame(width: 32, height: 32)
            }
            .buttonStyle(IconButtonPressStyle())
            .disabled(state.isBrowsing)
            PrivacyPillView {
                nav.presentedSheet = .privacy
            }
        }
        .padding(.horizontal, theme.pad)
        .padding(.top, 8)
    }

    @ViewBuilder
    private var filterBar: some View {
        HStack {
            if state.isBrowsing {
                Text("Loading…")
                    .font(Typography.uiBody())
                    .foregroundStyle(theme.ink3)
            } else {
                Text("\(displayedWorks.count) works")
                    .font(Typography.uiBody())
                    .foregroundStyle(theme.ink2)
            }

            Spacer()

            Button {
                withAnimation(.easeInOut(duration: 0.2)) { showFilters.toggle() }
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: "line.3.horizontal.decrease")
                        .font(.system(size: 13, weight: .semibold))
                    Text("Filter")
                        .font(Typography.uiSmall())
                }
                .foregroundStyle(showFilters ? theme.accent : theme.ink3)
                .padding(.horizontal, 12)
                .frame(height: 32)
                .background(
                    RoundedRectangle(cornerRadius: Radius.chip)
                        .fill(showFilters ? theme.accentSoft : theme.surface2)
                )
            }
            .buttonStyle(ChipPressStyle())
        }
    }

    private var filterControls: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Sort
            HStack {
                Text("Sort")
                    .font(Typography.uiSmall())
                    .foregroundStyle(theme.ink3)
                    .textCase(.uppercase)
                Spacer()
            }
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(SortOption.allCases, id: \.self) { option in
                        ChipView(label: option.rawValue, isSelected: sortBy == option) {
                            sortBy = option
                        }
                    }
                }
            }

            // Rating
            HStack {
                Text("Rating")
                    .font(Typography.uiSmall())
                    .foregroundStyle(theme.ink3)
                    .textCase(.uppercase)
                Spacer()
            }
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(RatingFilter.allCases, id: \.self) { option in
                        ChipView(label: option.rawValue, isSelected: filterRating == option) {
                            filterRating = option
                        }
                    }
                }
            }

            // Completion
            HStack {
                Text("Status")
                    .font(Typography.uiSmall())
                    .foregroundStyle(theme.ink3)
                    .textCase(.uppercase)
                Spacer()
            }
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(CompleteFilter.allCases, id: \.self) { option in
                        ChipView(label: option.rawValue, isSelected: filterComplete == option) {
                            filterComplete = option
                        }
                    }
                }
            }

            // Hide explicit
            HStack {
                Button {
                    state.hideExplicit.toggle()
                } label: {
                    HStack(spacing: 5) {
                        Image(systemName: state.hideExplicit ? "eye.slash" : "eye")
                            .font(.system(size: 13, weight: .semibold))
                        Text(state.hideExplicit ? "Hiding explicit" : "Showing all")
                            .font(Typography.uiSmall())
                    }
                    .foregroundStyle(state.hideExplicit ? theme.accent : theme.ink3)
                    .padding(.horizontal, 12)
                    .frame(height: 32)
                    .background(
                        RoundedRectangle(cornerRadius: Radius.chip)
                            .fill(state.hideExplicit ? theme.accentSoft : theme.surface2)
                    )
                }
                .buttonStyle(ChipPressStyle())
                Spacer()
            }
        }
        .transition(.opacity.combined(with: .move(edge: .top)))
    }
}

#Preview {
    BrowseView()
        .environment(AppTheme())
        .environment(AppState())
        .environment(NavigationState())
}
