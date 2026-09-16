import SwiftUI

/// The Search tab, driven by the shared `SearchModel`: a wrapping scope
/// control (Works / Collections / Bookmarks / Tags / Users), a Library |
/// AO3 source control, the scope's criteria form, and — once a query runs
/// — the results state with its back arrow, pager, list filter and
/// server-side sort. Tag pills anywhere in the app land here through
/// `NavigationState.openTag`.
struct SearchView: View {
    @Environment(AppTheme.self) private var theme
    @Environment(AppState.self) private var state
    @Environment(NavigationState.self) private var nav
    @Environment(SearchModel.self) private var search
    @Environment(LibraryListModel.self) private var lists

    var initialShowFilters: Bool = false
    /// Screenshot harness only: seed the criteria fields without a library.
    var initialFormFields: [UFormField]? = nil

    @State private var showFilters = false
    @State private var didApplyInitialFilters = false
    @State private var showFilterSheet = false
    @State private var showBookmarkFilterSheet = false

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
    private func consumePendingQueries() {
        if let tag = nav.pendingTagQuery {
            nav.pendingTagQuery = nil
            search.startTagQuery(tag, appState: state)
        }
        if let tag = nav.pendingAO3TagListing {
            nav.pendingAO3TagListing = nil
            search.startAO3TagListing(tag, appState: state)
        }
    }

    // MARK: - Header

    private var header: some View {
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
            }
        }
        .padding(.horizontal, theme.pad)
        .padding(.top, 8)
        .padding(.bottom, 10)
    }

    /// Wrapping scope control — never a sideways strip.
    private var scopeControl: some View {
        SegmentedControlView(
            selection: Binding(get: { search.scope }, set: { search.setScope($0) }),
            items: SearchModel.SearchScope.allCases.map { (key: $0, label: $0.rawValue) }
        )
    }

    /// Library | AO3. The model owns the flag; flipping it while results
    /// show re-runs the query under the new source.
    private var sourceControl: some View {
        SegmentedControlView(
            selection: Binding(get: { search.searchLibraryOnly },
                               set: { if $0 != search.searchLibraryOnly { search.toggleSearchSource(state) } }),
            items: [(key: true, label: "Library"), (key: false, label: "AO3")]
        )
    }

    @ViewBuilder
    private var formControls: some View {
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
    private var resultsControls: some View {
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

    private var backLabel: String {
        if search.canReturnToCollectionHits { return "Back to collections results" }
        if nav.searchReturnTab != nil { return "Back" }
        return "Back to search criteria"
    }

    /// One level out: the collections hit list behind a drill-in, the tab
    /// that triggered the search when it came from outside, the form
    /// otherwise.
    private func goBack() {
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

    private var resultsTitle: String {
        if let title = search.splitCollectionTitle { return title }
        if case .tag(let tag) = search.activeQuery { return tag }
        if case .collection = search.activeQuery, search.canReturnToCollectionHits { return "Collection" }
        return search.scope == .works ? "Results" : "\(search.scope.rawValue) results"
    }

    /// Results subtitle per scope: works-style results carry the page
    /// position and total; the others report their hit counts.
    private var resultsSubtitle: String? {
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

    private var sortColumnField: UFormField? {
        search.formFields.first { $0.name.hasSuffix("[sort_column]") }
    }

    private var sortDirectionField: UFormField? {
        search.formFields.first { $0.name.hasSuffix("[sort_direction]") }
    }

    /// AO3 pre-selects a default when the field is unset in the request
    /// behind the current results.
    private func currentSortValue(of field: UFormField) -> String {
        search.activeWorksRequest?.fieldValues[field.name]
            ?? field.options.first { $0.selected }?.value ?? ""
    }

    @ViewBuilder
    private var resultsSortMenu: some View {
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

    private func sortSelectionBinding(for field: UFormField) -> Binding<String> {
        Binding(
            get: { currentSortValue(of: field) },
            set: { search.updateWorksSearchField(field.name, value: $0, appState: state) }
        )
    }

    // MARK: - Form

    private var formScroll: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                if search.scope == .works {
                    worksForm
                } else {
                    ScopeSearchForm()
                }
            }
            .padding(.horizontal, theme.pad)
            .padding(.bottom, 32)
        }
        .scrollDismissesKeyboard(.interactively)
    }

    @ViewBuilder
    private var worksForm: some View {
        SavedSearchField()

        queryField

        if search.isLoadingForm {
            HStack(spacing: 8) {
                ProgressView().controlSize(.small).tint(theme.ink3)
                Text("Loading criteria from the archive…")
                    .font(Typography.uiSmall())
                    .foregroundStyle(theme.ink3)
            }
        } else if let error = search.formError {
            NetworkErrorView(message: error, onRetry: {
                Task { await search.scrapeForm(state) }
            })
        } else if search.formFields.isEmpty {
            Text("Search criteria haven’t been loaded yet. Use the ↻ button above to fetch them from AO3.")
                .font(Typography.uiSmall())
                .foregroundStyle(theme.ink3)
                .fixedSize(horizontal: false, vertical: true)
        } else {
            HStack {
                Button {
                    withAnimation(.easeInOut(duration: 0.2)) { showFilters.toggle() }
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: showFilters ? "chevron.up" : "chevron.down")
                            .font(.system(size: 11, weight: .bold))
                        Text(showFilters ? "Hide filters" : "More filters")
                            .font(Typography.uiCaption())
                    }
                    .foregroundStyle(theme.accent)
                }
                Spacer()
                if search.activeFilterCount > 0 {
                    Text(search.activeFilterCount == 1
                         ? "1 filter active" : "\(search.activeFilterCount) filters active")
                        .font(Typography.uiCaption())
                        .foregroundStyle(theme.accent)
                    Button("Clear") { search.clearFilters() }
                        .font(Typography.uiCaption())
                        .foregroundStyle(theme.ink3)
                }
            }

            if showFilters {
                VStack(alignment: .leading, spacing: 12) {
                    ForEach(search.filterFields, id: \.name) { field in
                        fieldControl(field)
                    }
                }
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }

        Button { search.performScopedSearch(state) } label: {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 14, weight: .semibold))
                Text("Search")
                    .font(Typography.buttonLabel())
            }
            .foregroundStyle(theme.onAccent)
            .frame(maxWidth: .infinity)
            .frame(height: 48)
            .background(RoundedRectangle(cornerRadius: Radius.button).fill(theme.accent))
        }
        .buttonStyle(ButtonPressStyle())
        .padding(.top, 4)

        SearchSourceFooter()
    }

    private var queryField: some View {
        @Bindable var search = search
        return VStack(alignment: .leading, spacing: 4) {
            fieldLabel("Query")
            HStack(spacing: 8) {
                Image(systemName: "text.magnifyingglass")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(theme.ink3)
                TextField("Any field — title, author, tags…", text: $search.queryText)
                    .textFieldStyle(.plain)
                    .font(.custom("HankenGrotesk", size: 15).weight(.medium))
                    .foregroundStyle(theme.ink)
                    .submitLabel(.search)
                    .onSubmit { search.performScopedSearch(state) }
            }
            .padding(.horizontal, 12)
            .frame(height: 42)
            .background(theme.surface2)
            .clipShape(RoundedRectangle(cornerRadius: 10))
        }
    }

    /// AO3's canonical-tag inputs get the token field with local-cache
    /// autocomplete; everything else renders by field type.
    @ViewBuilder
    private func fieldControl(_ field: UFormField) -> some View {
        if let tagType = Self.tagType(for: field.name) {
            TagTokenField(label: field.label, tagType: tagType, value: binding(for: field.name))
        } else {
            switch field.fieldType {
            case "select":
                selectFieldView(field, defaultValue: "")
            case "radio":
                // AO3 pre-checks the no-filter option; the scraped
                // `selected` flag supplies that default.
                selectFieldView(field, defaultValue: field.options.first { $0.selected }?.value
                                ?? field.options.first?.value ?? "")
            case "checkboxes":
                checkboxGroupView(field)
            case "hidden":
                EmptyView()
            default:
                textFieldView(field)
            }
        }
    }

    static func tagType(for fieldName: String) -> String? {
        switch fieldName {
        case "work_search[fandom_names]": "fandom"
        case "work_search[character_names]": "character"
        case "work_search[relationship_names]": "relationship"
        case "work_search[freeform_names]": "freeform"
        case "work_search[creators]": "creator"
        default: nil
        }
    }

    private func fieldLabel(_ text: String) -> some View {
        Text(text.uppercased())
            .font(.custom("HankenGrotesk", size: 10.5).weight(.bold))
            .tracking(0.6)
            .foregroundStyle(theme.ink3)
    }

    /// AO3 selects mark their no-filter option with a blank label — surface
    /// those as "Any" so the control always shows a value.
    private static func optionTitle(_ label: String) -> String {
        let trimmed = label.trimmingCharacters(in: .whitespaces)
        return trimmed.isEmpty ? "Any" : trimmed
    }

    private func textFieldView(_ field: UFormField) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            if !field.label.isEmpty { fieldLabel(field.label) }
            TextField(Self.placeholderHint(for: field), text: binding(for: field.name))
                .font(.custom("HankenGrotesk", size: 15).weight(.medium))
                .foregroundStyle(theme.ink)
                .autocorrectionDisabled()
                .padding(.horizontal, 12)
                .frame(height: 42)
                .background(theme.surface2)
                .clipShape(RoundedRectangle(cornerRadius: 10))
                .submitLabel(.search)
                .onSubmit { search.performScopedSearch(state) }
        }
    }

    private func selectFieldView(_ field: UFormField, defaultValue: String) -> some View {
        let current = search.fieldValues[field.name] ?? defaultValue
        let title = Self.optionTitle(field.options.first { $0.value == current }?.label
                                     ?? field.options.first?.label ?? "")
        return VStack(alignment: .leading, spacing: 4) {
            if !field.label.isEmpty { fieldLabel(field.label) }
            Menu {
                ForEach(field.options, id: \.value) { option in
                    Button {
                        search.fieldValues[field.name] = option.value
                    } label: {
                        if option.value == current {
                            Label(Self.optionTitle(option.label), systemImage: "checkmark")
                        } else {
                            Text(Self.optionTitle(option.label))
                        }
                    }
                }
            } label: {
                SearchDropdownLabel(title: title)
            }
        }
    }

    private func checkboxGroupView(_ field: UFormField) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            if !field.label.isEmpty { fieldLabel(field.label) }
            FlowLayout(spacing: 6) {
                ForEach(field.options, id: \.value) { option in
                    let selected = search.checkboxValues[field.name]?.contains(option.value) ?? false
                    Button {
                        var set = search.checkboxValues[field.name] ?? []
                        if selected { set.remove(option.value) } else { set.insert(option.value) }
                        search.checkboxValues[field.name] = set
                    } label: {
                        Text(option.label)
                            .font(.custom("HankenGrotesk", size: 12).weight(.semibold))
                            .foregroundStyle(selected ? theme.onAccent : theme.ink2)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 6)
                            .background(
                                RoundedRectangle(cornerRadius: Radius.chip)
                                    .fill(selected ? theme.accent : theme.surface)
                            )
                            .overlay(
                                RoundedRectangle(cornerRadius: Radius.chip)
                                    .stroke(selected ? theme.accent : theme.line, lineWidth: 1)
                            )
                    }
                    .buttonStyle(ChipPressStyle())
                }
            }
        }
    }

    /// AO3's stat fields silently accept range syntax; the scraped form
    /// carries no placeholders, so surface the syntax here.
    private static let rangeFieldSuffixes = [
        "[word_count]", "[hits]", "[kudos_count]", "[comments_count]", "[bookmarks_count]",
    ]

    private static func placeholderHint(for field: UFormField) -> String {
        if !field.placeholder.isEmpty { return field.placeholder }
        if rangeFieldSuffixes.contains(where: { field.name.hasSuffix($0) }) {
            return ">1000 · <500 · 100-5000"
        }
        if field.name.hasSuffix("[revised_at]") {
            return "e.g. 2024, or < 2 weeks ago"
        }
        return field.label
    }

    private func binding(for name: String) -> Binding<String> {
        Binding(
            get: { search.fieldValues[name] ?? "" },
            set: { search.fieldValues[name] = $0 }
        )
    }
}

/// Type-to-look-up field over the user's saved searches: typing filters
/// the saved list by name — no network, the list is already loaded from
/// the database. Picking one prefills the whole criteria form (ready to
/// tweak and run); clearing the text only clears the field, never the
/// form. Each suggestion row carries a × to delete that saved search. The
/// Save button persists the current criteria under the typed name
/// (Update when the name already exists).
private struct SavedSearchField: View {
    @Environment(AppTheme.self) private var theme
    @Environment(AppState.self) private var state
    @Environment(SearchModel.self) private var search

    @State private var input = ""
    @FocusState private var focused: Bool

    private var term: String {
        input.trimmingCharacters(in: .whitespaces)
    }

    /// Names are unique in the database (case-insensitively) — saving to an
    /// existing name overwrites that search, so the button reads Update.
    private var nameExists: Bool {
        search.savedSearches.contains { $0.name.caseInsensitiveCompare(term) == .orderedSame }
    }

    /// Saved searches are a short, already-loaded list — focusing shows
    /// them all, typing narrows by name.
    private var matches: [USavedSearch] {
        guard !term.isEmpty else { return search.savedSearches }
        return search.savedSearches.filter { $0.name.localizedCaseInsensitiveContains(term) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("SAVED SEARCH")
                .font(.custom("HankenGrotesk", size: 10.5).weight(.bold))
                .tracking(0.6)
                .foregroundStyle(theme.ink3)
            HStack(spacing: 8) {
                Image(systemName: "star")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(theme.ink3)
                TextField("Type to find a saved search…", text: $input)
                    .textFieldStyle(.plain)
                    .font(.custom("HankenGrotesk", size: 15).weight(.medium))
                    .foregroundStyle(theme.ink)
                    .autocorrectionDisabled()
                    .focused($focused)
                    .submitLabel(.done)
                    .onSubmit { save() }
                Button(nameExists ? "Update" : "Save") { save() }
                    .font(Typography.smallButtonLabel())
                    .foregroundStyle(term.isEmpty ? theme.ink3 : theme.accent)
                    .disabled(term.isEmpty)
                    .fixedSize()
            }
            .padding(.horizontal, 12)
            .frame(height: 42)
            .background(theme.surface2)
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10)
                .stroke(focused ? theme.accent : theme.line, lineWidth: 1))

            if focused && !matches.isEmpty {
                suggestionList
            }
        }
    }

    private func save() {
        guard !term.isEmpty else { return }
        search.saveCurrentSearch(named: term, appState: state)
        focused = false
    }

    private var suggestionList: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(matches, id: \.id) { saved in
                HStack(spacing: 6) {
                    Button {
                        search.applySavedSearch(saved)
                        input = saved.name
                        focused = false
                    } label: {
                        VStack(alignment: .leading, spacing: 1) {
                            Text(saved.name)
                                .font(Typography.uiBody())
                                .foregroundStyle(theme.ink)
                                .lineLimit(1)
                            if let summary = SearchModel.summary(of: saved) {
                                Text(summary)
                                    .font(Typography.uiSmall())
                                    .foregroundStyle(theme.ink3)
                                    .lineLimit(1)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    Button {
                        search.deleteSavedSearch(saved.id, appState: state)
                    } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 11, weight: .bold))
                            .foregroundStyle(theme.ink3)
                            .frame(width: 28, height: 28)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Delete saved search \(saved.name)")
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
            }
        }
        .padding(.vertical, 4)
        .background(theme.surface)
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(theme.line, lineWidth: 1))
    }
}

#Preview {
    SearchView()
        .environment(AppTheme())
        .environment(AppState())
        .environment(NavigationState())
}
