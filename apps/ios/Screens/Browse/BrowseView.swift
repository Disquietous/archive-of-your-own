import SwiftUI

/// Latest Works (the former Browse tab, now pushed from the Search
/// landing): AO3's latest-works listing, ordered and filtered by the
/// shared list model under its own persisted Sort & Filter prefs (the
/// `.browse` slot) and session list filter. Opening it is the only thing
/// that loads the listing.
struct BrowseView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(AppTheme.self) private var theme
    @Environment(AppState.self) private var state
    @Environment(NavigationState.self) private var nav
    @Environment(LibraryListModel.self) private var lists

    @State private var showFilterSheet = false
    @State private var newListFor: Work?
    @State private var newListName = ""
    @State private var exportedEpub: EpubExporter.Exported?
    @State private var exportError: String?

    private var displayedWorks: [Work] {
        lists.works(for: .browse, raw: state.browseResults)
    }

    private var filterActive: Bool {
        lists.workListFilter(for: .browse).isActive
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: theme.rowGap) {
                masthead
                statusBar.padding(.horizontal, theme.pad)

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
                    if filterActive && !state.browseResults.isEmpty {
                        VStack(spacing: 12) {
                            EmptyStateView(systemImage: "line.3.horizontal.decrease.circle",
                                           title: "Nothing matches",
                                           subtitle: "No works in this list match the current filter.")
                            Button("Clear Filter") { lists.workListFilters[.browse] = nil }
                                .font(Typography.smallButtonLabel())
                                .foregroundStyle(theme.accent)
                                .buttonStyle(ButtonPressStyle())
                        }
                        .padding(.top, 40)
                    } else {
                        EmptyStateView(
                            systemImage: "book",
                            title: "No works",
                            subtitle: "Check your connection and try again."
                        )
                        .padding(.top, 40)
                    }
                } else {
                    LazyVStack(spacing: theme.rowGap) {
                        ForEach(displayedWorks) { work in
                            WorkCardView(
                                work: work,
                                blurExplicit: state.hideExplicit && work.rating == .explicit,
                                onAuthorTap: UInt64(work.id) != nil ? {
                                    nav.openAuthor(AppState.canonicalAuthorUsername(work.author))
                                } : nil,
                                onTap: { nav.openWork(work.id) }
                            )
                            .contextMenu {
                                WorkRowMenu(work: work, onNewReadingList: { newListFor = $0 },
                                            onExportEpub: { exportEpub($0) })
                            }
                        }

                        if !state.isBrowsing {
                            Button {
                                Task { await state.browseLatestWorks() }
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
        .libraryScreen()
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
        .sheet(isPresented: $showFilterSheet) {
            WorkListFilterSheet(section: .browse,
                                availableTags: lists.availableTags(for: .browse, raw: state.browseResults),
                                availableFandoms: lists.availableFandoms(for: .browse, raw: state.browseResults))
                .environment(theme)
                .environment(lists)
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

    private var masthead: some View {
        HStack(spacing: 8) {
            Button { dismiss() } label: {
                Image(systemName: "chevron.left")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(theme.ink)
                    .frame(width: 36, height: 36)
            }
            .buttonStyle(IconButtonPressStyle())
            .accessibilityLabel("Back")
            Text("Latest Works")
                .font(Typography.uiBody())
                .foregroundStyle(theme.ink)
                .lineLimit(1)
            Spacer()
            ChromeIconButton(symbol: "arrow.clockwise", isBusy: state.isBrowsing) {
                state.bridge.invalidateSessionCache(key: "browse")
                state.browseResults = []
                state.browseCurrentPage = 0
                Task { await state.browseLatestWorks(force: true) }
            }
            .disabled(state.isBrowsing)
            .accessibilityLabel("Reload latest works")
            ChromeIconButton(symbol: state.hideExplicit ? "eye.slash" : "eye",
                             tint: state.hideExplicit ? theme.accent : nil) {
                state.hideExplicit.toggle()
            }
            .accessibilityLabel(state.hideExplicit ? "Show explicit works" : "Hide explicit works")
            SortFilterMenu(section: .browse)
            ChromeIconButton(symbol: filterActive ? "line.3.horizontal.decrease.circle.fill"
                                                   : "line.3.horizontal.decrease.circle",
                             tint: filterActive ? theme.accent : nil) {
                showFilterSheet = true
            }
            .accessibilityLabel("Filter this list")
            PrivacyPillView {
                nav.presentedSheet = .privacy
            }
        }
        .padding(.horizontal, theme.pad)
        .padding(.top, 8)
    }

    private var statusBar: some View {
        HStack {
            if state.isBrowsing && displayedWorks.isEmpty {
                Text("Loading…")
                    .font(Typography.uiBody())
                    .foregroundStyle(theme.ink3)
            } else {
                let count = displayedWorks.count
                Text(filterActive
                     ? "\(count) of \(state.browseResults.count) works"
                     : (count == 1 ? "1 work" : "\(count) works"))
                    .font(Typography.uiBody())
                    .foregroundStyle(theme.ink2)
            }

            Spacer()
        }
    }
}

#Preview {
    BrowseView()
        .environment(AppTheme())
        .environment(AppState())
        .environment(NavigationState())
}
