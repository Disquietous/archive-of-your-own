import SwiftUI

extension SearchView {
    // MARK: - Header

    var header: some View {
        VStack(spacing: 10) {
            HStack(spacing: 8) {
                if search.showingResults {
                    Button { goBack() } label: {
                        Image(systemName: "chevron.left")
                            .font(.system(size: 17, weight: .semibold))
                            .foregroundStyle(theme.ink)
                            .frame(width: 36, height: 36)
                    }
                    .buttonStyle(IconButtonPressStyle())
                    .accessibilityLabel(backLabel)

                    VStack(alignment: .leading, spacing: 1) {
                        Text(resultsTitle)
                            .font(Typography.uiBody())
                            .foregroundStyle(theme.ink)
                            .lineLimit(1)
                        if let sub = resultsSubtitle {
                            Text(sub)
                                .font(.custom("HankenGrotesk", size: 11).weight(.medium))
                                .foregroundStyle(theme.ink3)
                                .lineLimit(1)
                        }
                    }
                } else {
                    Text("Search")
                        .font(Typography.browseTitle())
                        .foregroundStyle(theme.ink)
                }

                Spacer(minLength: 4)

                if search.showingResults {
                    resultsControls
                } else {
                    formControls
                }

                PrivacyPillView { nav.presentedSheet = .privacy }
            }

            if !search.showingResults {
                scopeControl
                sourceControl
                browseEntries
            }
        }
        .padding(.horizontal, theme.pad)
        .padding(.top, 8)
        .padding(.bottom, 10)
    }

    /// The former Browse tab's two lists, reached from here.
    var browseEntries: some View {
        HStack(spacing: 8) {
            browseChip("Latest Works", systemImage: "clock.arrow.circlepath") { nav.openLatestWorks() }
            browseChip("Collections", systemImage: "square.grid.2x2") { nav.openCollections() }
            Spacer(minLength: 0)
        }
    }

    func browseChip(_ title: String, systemImage: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Image(systemName: systemImage)
                    .font(.system(size: 13, weight: .semibold))
                Text(title)
                    .font(Typography.uiSmall())
            }
            .foregroundStyle(theme.ink2)
            .padding(.horizontal, 12)
            .frame(height: 32)
            .background(RoundedRectangle(cornerRadius: Radius.chip).fill(theme.surface2))
        }
        .buttonStyle(ChipPressStyle())
    }

    /// Wrapping scope control — never a sideways strip.
    var scopeControl: some View {
        SegmentedControlView(
            selection: Binding(get: { search.scope }, set: { search.setScope($0) }),
            items: SearchModel.SearchScope.allCases.map { (key: $0, label: $0.rawValue) }
        )
    }

    /// Library | AO3. The model owns the flag; flipping it while results
    /// show re-runs the query under the new source.
    var sourceControl: some View {
        SegmentedControlView(
            selection: Binding(get: { search.searchLibraryOnly },
                               set: { if $0 != search.searchLibraryOnly { search.toggleSearchSource(state) } }),
            items: [(key: true, label: "Library"), (key: false, label: "AO3")]
        )
    }

    @ViewBuilder
    var formControls: some View {
        if search.scope == .works {
            ChromeIconButton(symbol: "arrow.clockwise", isBusy: search.isLoadingForm) {
                Task { await search.scrapeForm(state) }
            }
            .disabled(search.isLoadingForm)
            .accessibilityLabel("Reload search criteria from AO3")
            ChromeIconButton(symbol: state.hideExplicit ? "eye.slash" : "eye",
                             tint: state.hideExplicit ? theme.accent : nil) {
                state.hideExplicit.toggle()
            }
            .accessibilityLabel(state.hideExplicit ? "Show explicit works" : "Hide explicit works")
        }
    }

    @ViewBuilder
    var resultsControls: some View {
        if search.splitCollectionName == nil {
            if search.scope == .works {
                if search.hasSearched, case .form = search.activeQuery, sortColumnField != nil {
                    resultsSortMenu
                }
                if search.hasSearched {
                    SortFilterMenu(section: .search)
                    let active = lists.workListFilter(for: .search).isActive
                    ChromeIconButton(symbol: active ? "line.3.horizontal.decrease.circle.fill"
                                                   : "line.3.horizontal.decrease.circle",
                                     tint: active ? theme.accent : nil) {
                        showFilterSheet = true
                    }
                    .accessibilityLabel("Filter the fetched results (this page only)")
                }
            } else if search.scope == .bookmarks, search.hasSearched {
                let active = search.bookmarkListFilter.isActive
                ChromeIconButton(symbol: active ? "line.3.horizontal.decrease.circle.fill"
                                               : "line.3.horizontal.decrease.circle",
                                 tint: active ? theme.accent : nil) {
                    showBookmarkFilterSheet = true
                }
                .accessibilityLabel("Filter the fetched results (this page only)")
            }
        } else if let name = search.splitCollectionName,
                  let url = ExternalLinkOpener.ao3CollectionURL(name) {
            ChromeIconButton(symbol: "arrow.up.right") {
                ExternalLinkOpener.open(url, bridge: state.bridge)
            }
            .accessibilityLabel("Open this collection on AO3")
        }
        // Source toggle: internaldrive = only the app's database, globe =
        // full search on AO3. Flipping re-runs the showing results.
        ChromeIconButton(symbol: search.searchLibraryOnly ? "internaldrive" : "globe",
                         tint: search.searchLibraryOnly ? nil : theme.accent) {
            search.toggleSearchSource(state)
        }
        .accessibilityLabel(search.searchLibraryOnly
                            ? "Searching your library only — tap to search AO3"
                            : "Searching AO3 — tap to search only your library")
    }

    var backLabel: String {
        if search.canReturnToCollectionHits { return "Back to collections results" }
        if nav.searchReturnTab != nil { return "Back" }
        return "Back to search criteria"
    }

    /// One level out: the collections hit list behind a drill-in, the tab
    /// that triggered the search when it came from outside, the form
    /// otherwise.
    func goBack() {
        if search.splitCollectionName != nil {
            search.closeSplitCollection()
            return
        }
        if !search.canReturnToCollectionHits, let target = nav.searchReturnTab {
            nav.searchReturnTab = nil
            search.showingResults = false
            nav.selectedTab = target
            return
        }
        search.returnToForm()
    }

    var resultsTitle: String {
        if let title = search.splitCollectionTitle { return title }
        if case .tag(let tag) = search.activeQuery { return tag }
        if case .collection = search.activeQuery, search.canReturnToCollectionHits { return "Collection" }
        return search.scope == .works ? "Results" : "\(search.scope.rawValue) results"
    }

    /// Results subtitle per scope: works-style results carry the page
    /// position and total; the others report their hit counts.
    var resultsSubtitle: String? {
        if search.splitCollectionName != nil {
            var parts: [String] = []
            if let works = search.totalWorks { parts.append(works == 1 ? "1 work" : "\(works) works") }
            if let items = search.bookmarksTotal {
                parts.append(items == 1 ? "1 bookmarked item" : "\(items) bookmarked items")
            }
            return parts.isEmpty ? nil : parts.joined(separator: " · ")
        }
        switch search.scope {
        case .works:
            var parts: [String] = []
            if let sub = search.resultsSubtitle { parts.append(sub) }
            if lists.workListFilter(for: .search).isActive {
                let shown = lists.works(for: .search, raw: state.searchResults).count
                parts.append("\(shown) of \(state.searchResults.count) shown")
            }
            return parts.isEmpty ? nil : parts.joined(separator: " · ")
        case .bookmarks:
            var parts: [String] = []
            if case .bookmarkSearch = search.activeQuery {
                parts.append(search.totalPages > 1
                    ? "Page \(search.currentPage) of \(search.totalPages)"
                    : "Page \(search.currentPage)")
            }
            if search.bookmarkListFilter.isActive {
                parts.append("\(search.filteredBookmarkHits.count) of \(search.bookmarkHits.count) bookmarks")
            } else {
                let total = search.totalWorks.map(Int.init) ?? search.bookmarkHits.count
                parts.append(total == 1 ? "1 bookmark" : "\(total) bookmarks")
            }
            return parts.joined(separator: " · ")
        case .tags:
            return search.tagHits.count == 1 ? "1 tag" : "\(search.tagHits.count) tags"
        case .users:
            return search.userHits.count == 1 ? "1 user" : "\(search.userHits.count) users"
        case .collections:
            let count = search.collectionHits.count == 1
                ? "1 collection" : "\(search.collectionHits.count) collections"
            if case .collectionsIndex = search.activeQuery, let sub = search.resultsSubtitle {
                return "\(sub) · \(count)"
            }
            return count
        }
    }

    // MARK: - Server-side sort (re-runs the active works request)

    var sortColumnField: UFormField? {
        search.formFields.first { $0.name.hasSuffix("[sort_column]") }
    }

    var sortDirectionField: UFormField? {
        search.formFields.first { $0.name.hasSuffix("[sort_direction]") }
    }

    /// AO3 pre-selects a default when the field is unset in the request
    /// behind the current results.
    func currentSortValue(of field: UFormField) -> String {
        search.activeWorksRequest?.fieldValues[field.name]
            ?? field.options.first { $0.selected }?.value ?? ""
    }

    @ViewBuilder
    var resultsSortMenu: some View {
        if let sortField = sortColumnField {
            Menu {
                Picker("Sort By", selection: sortSelectionBinding(for: sortField)) {
                    ForEach(sortField.options.filter { !$0.label.trimmingCharacters(in: .whitespaces).isEmpty },
                            id: \.value) { option in
                        Text(option.label.trimmingCharacters(in: .whitespaces)).tag(option.value)
                    }
                }
                .pickerStyle(.inline)
                if let directionField = sortDirectionField {
                    Picker("Direction", selection: sortSelectionBinding(for: directionField)) {
                        ForEach(directionField.options.filter { !$0.label.trimmingCharacters(in: .whitespaces).isEmpty },
                                id: \.value) { option in
                            Text(option.label.trimmingCharacters(in: .whitespaces)).tag(option.value)
                        }
                    }
                    .pickerStyle(.inline)
                }
            } label: {
                Image(systemName: "arrow.up.arrow.down.square")
                    .font(.system(size: 16, weight: .medium))
                    .foregroundStyle(theme.ink2)
                    .frame(width: 36, height: 36)
            }
            .accessibilityLabel("Sort results (re-runs the search)")
        }
    }

    func sortSelectionBinding(for field: UFormField) -> Binding<String> {
        Binding(
            get: { currentSortValue(of: field) },
            set: { search.updateWorksSearchField(field.name, value: $0, appState: state) }
        )
    }
}
