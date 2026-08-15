import SwiftUI

/// The criteria form for the non-works search scopes (Collections,
/// Bookmarks, Tags, Users): one query field — Bookmarks/Tags/Users search
/// by name, while Collections adds the full sort/filter criteria AO3's
/// /collections index accepts (tags, multifandom/closed/moderated,
/// challenge type, sort). Return runs the search; the footer explains what
/// the source toggle means for this scope.
struct ScopeSearchFormView: View {
    @Bindable var theme: AppTheme
    @Bindable var appState: AppState
    @Bindable var model: MacAppModel

    @FocusState private var focused: Bool

    private var placeholder: String {
        switch model.search.scope {
        case .works: ""
        case .collections: "Filter by title…"
        case .bookmarks: "Title, author, tag, or summary…"
        case .tags: "Tag name…"
        case .users: "Username…"
        }
    }

    var body: some View {
        let search = model.search
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 7) {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(theme.ink3)
                    TextField(placeholder, text: Bindable(search).scopeQuery)
                        .textFieldStyle(.plain)
                        .font(Font(MacFont.ui(13)))
                        .foregroundStyle(theme.ink)
                        .focused($focused)
                        .onSubmit { search.performScopedSearch(appState) }
                }
                .padding(.horizontal, 10)
                .frame(height: 34)
                .background(theme.surface)
                .clipShape(RoundedRectangle(cornerRadius: 9))
                .overlay(RoundedRectangle(cornerRadius: 9)
                    .stroke(focused ? theme.accent : theme.line, lineWidth: 1))

                if search.scope == .collections {
                    collectionsCriteria(search)
                }

                if search.scope == .bookmarks {
                    bookmarksCriteria(search)
                }

                if let notice = search.scopeNotice {
                    HStack(spacing: 8) {
                        Image(systemName: "info.circle")
                            .font(.system(size: 12, weight: .medium))
                        Text(notice)
                            .font(Font(MacFont.ui(12)))
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .foregroundStyle(theme.ink2)
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(theme.accentSoft)
                    .clipShape(RoundedRectangle(cornerRadius: 9))
                }

                Text(search.searchLibraryOnly
                    ? "Searching your library — everything the app has already fetched and cached. Nothing leaves the device."
                    : "Searching AO3 — results come from the archive over Tor.")
                    .font(Font(MacFont.ui(11.5)))
                    .foregroundStyle(theme.ink3)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(16)
            .frame(maxWidth: 560)
            .frame(maxWidth: .infinity)
        }
        .onAppear { focused = true }
        .task(id: search.scope) {
            // The bookmarks form borrows the works form's language options —
            // cache-only, never a fetch of its own.
            if search.scope == .bookmarks {
                search.loadCachedFormIfAvailable(appState)
            }
        }
    }

    // MARK: - Collections criteria (mirrors AO3's /collections filter form)

    private static let triState: [(value: String, label: String)] =
        [("", "Either"), ("true", "Yes"), ("false", "No")]

    @ViewBuilder
    private func collectionsCriteria(_ search: MacSearchModel) -> some View {
        // Any-type tag tokens ("" tagType): suggestions come from the whole
        // library tag cache, like every other tag field in the app.
        TagTokenField(theme: theme, appState: appState,
                      label: "Tags", tagType: "",
                      value: Bindable(search).collectionTags)
        pillRow("Multifandom", options: Self.triState,
                selection: Bindable(search).collectionMultifandom)
        pillRow("Closed", options: Self.triState,
                selection: Bindable(search).collectionClosed)
        pillRow("Moderated", options: Self.triState,
                selection: Bindable(search).collectionModerated)
        pillRow("Collection type",
                options: [("", "Any"), ("GiftExchange", "Gift Exchange"),
                          ("PromptMeme", "Prompt Meme"), ("no_challenge", "No Challenge")],
                selection: Bindable(search).collectionChallengeType)
        pillRow("Sort by",
                options: [("created_at", "Date Created"), ("title.keyword", "Title"),
                          ("bookmarked_items_count", "Bookmarked Items"), ("works_count", "Works")],
                selection: Bindable(search).collectionSortColumn)
        pillRow("Sort direction",
                options: [("desc", "Descending"), ("asc", "Ascending")],
                selection: Bindable(search).collectionSortDirection)
    }

    // MARK: - Bookmarks criteria (mirrors AO3's /bookmarks/search form)

    /// The query field above doubles as the form's "any field on work"
    /// query; everything else follows the site's three fieldsets —
    /// bookmarked item, the bookmark itself, and sort.
    @ViewBuilder
    private func bookmarksCriteria(_ search: MacSearchModel) -> some View {
        TagTokenField(theme: theme, appState: appState,
                      label: "Work tags", tagType: "",
                      value: Bindable(search).bookmarkWorkTags)
        pillRow("Type", options: [("", "Any"), ("Work", "Work"), ("Series", "Series"),
                                  ("External Work", "External Work")],
                selection: Bindable(search).bookmarkType)
        textRow("Word count", placeholder: "e.g. >10000 or 1000-5000",
                text: Bindable(search).bookmarkWordCount)
        languageRow(search)
        textRow("Date updated", placeholder: "e.g. < 2 weeks ago or 2025",
                text: Bindable(search).bookmarkDateUpdated)

        sectionHeader("Bookmark")
        textRow("Any field on bookmark", placeholder: "Notes, tags…",
                text: Bindable(search).bookmarkQuery)
        TagTokenField(theme: theme, appState: appState,
                      label: "Bookmarker's tags", tagType: "",
                      value: Bindable(search).bookmarkerTags)
        textRow("Bookmarker", placeholder: "Username…",
                text: Bindable(search).bookmarkBookmarker)
        textRow("Notes", placeholder: "Text in the bookmarker's notes…",
                text: Bindable(search).bookmarkNotes)
        togglePillRow("Bookmark type", toggles: [
            ("Rec", Bindable(search).bookmarkRecOnly),
            ("With notes", Bindable(search).bookmarkWithNotesOnly)])
        textRow("Date bookmarked", placeholder: "e.g. < 1 month ago",
                text: Bindable(search).bookmarkDate)

        sectionHeader("Search")
        pillRow("Sort by",
                options: [("", "Best Match"), ("created_at", "Date Bookmarked"),
                          ("bookmarkable_date", "Date Updated"), ("word_count", "Word Count")],
                selection: Bindable(search).bookmarkSortColumn)
    }

    /// The work-language dropdown, populated from the scraped works form's
    /// language select (the two forms share AO3's language list). Hidden
    /// until the works criteria have been scraped at least once.
    @ViewBuilder
    private func languageRow(_ search: MacSearchModel) -> some View {
        if let field = search.formFields.first(where: { $0.name.contains("[language_id]") }) {
            let current = search.bookmarkLanguage
            let title = field.options.first { $0.value == current }
                .map { $0.label.trimmingCharacters(in: .whitespaces) }
                .flatMap { $0.isEmpty ? nil : $0 } ?? "Any"
            VStack(alignment: .leading, spacing: 5) {
                criteriaLabel("Work language")
                DropdownControl(
                    theme: theme, title: title,
                    options: field.options.map { option in
                        let label = option.label.trimmingCharacters(in: .whitespaces)
                        return (label: label.isEmpty ? "Any" : label,
                                value: option.value,
                                checked: option.value == current)
                    },
                    onPick: { search.bookmarkLanguage = $0 })
            }
        }
    }

    private func sectionHeader(_ title: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Divider().padding(.top, 4)
            Text(title.uppercased())
                .font(Font(MacFont.ui(10.5, weight: .bold)))
                .kerning(0.6)
                .foregroundStyle(theme.ink2)
        }
    }

    /// A labeled single-line text criterion; Return runs the search like
    /// the query field.
    private func textRow(_ title: String, placeholder: String,
                         text: Binding<String>) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            criteriaLabel(title)
            TextField(placeholder, text: text)
                .textFieldStyle(.plain)
                .font(Font(MacFont.ui(12.5)))
                .foregroundStyle(theme.ink)
                .onSubmit { model.search.performScopedSearch(appState) }
                .padding(.horizontal, 10)
                .frame(height: 30)
                .background(theme.surface)
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(theme.line, lineWidth: 1))
        }
    }

    /// Independent on/off pills (checkbox semantics) in the capsule grammar
    /// pillRow uses for its radio semantics.
    private func togglePillRow(_ title: String,
                               toggles: [(label: String, isOn: Binding<Bool>)]) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            criteriaLabel(title)
            FlowLayout(spacing: 6) {
                ForEach(Array(toggles.enumerated()), id: \.offset) { _, toggle in
                    let on = toggle.isOn.wrappedValue
                    Button {
                        toggle.isOn.wrappedValue.toggle()
                    } label: {
                        Text(toggle.label)
                            .font(Font(MacFont.ui(11.5, weight: .semibold)))
                            .foregroundStyle(on ? theme.onAccent : theme.ink2)
                            .padding(.horizontal, 9)
                            .padding(.vertical, 4)
                            .background(on ? theme.accent : theme.surface2)
                            .clipShape(Capsule())
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private func criteriaLabel(_ text: String) -> some View {
        Text(text.uppercased())
            .font(Font(MacFont.ui(10.5, weight: .bold)))
            .kerning(0.6)
            .foregroundStyle(theme.ink3)
    }

    /// A single-choice capsule row (the works form's checkbox-pill grammar,
    /// radio semantics): exactly one option is active; pills wrap instead
    /// of scrolling.
    private func pillRow(_ title: String, options: [(value: String, label: String)],
                         selection: Binding<String>) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            criteriaLabel(title)
            FlowLayout(spacing: 6) {
                ForEach(options, id: \.value) { option in
                    let on = selection.wrappedValue == option.value
                    Button {
                        selection.wrappedValue = option.value
                    } label: {
                        Text(option.label)
                            .font(Font(MacFont.ui(11.5, weight: .semibold)))
                            .foregroundStyle(on ? theme.onAccent : theme.ink2)
                            .padding(.horizontal, 9)
                            .padding(.vertical, 4)
                            .background(on ? theme.accent : theme.surface2)
                            .clipShape(Capsule())
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }
}

/// Header bar for one half of the split collection view (works |
/// bookmarked items). The works half carries the back arrow that returns
/// to the collections results list; each half carries its own pager, so
/// the two listings page independently.
struct CollectionSplitPaneHeader: View {
    @Bindable var theme: AppTheme
    @Bindable var appState: AppState
    @Bindable var model: MacAppModel
    let isWorks: Bool

    var body: some View {
        let search = model.search
        HStack(spacing: 8) {
            if isWorks {
                Button {
                    // Return to the collections hit list behind the panes.
                    search.closeSplitCollection()
                } label: {
                    Image(systemName: "arrow.left")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(theme.ink2)
                        .frame(width: 24, height: 24)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Back to collection results")
            }
            Text(isWorks ? "WORKS" : "BOOKMARKED ITEMS")
                .font(Font(MacFont.ui(10.5, weight: .bold)))
                .kerning(0.6)
                .foregroundStyle(theme.ink3)
            if let total = isWorks ? search.totalWorks : search.bookmarksTotal {
                Text("\(total)")
                    .font(Font(MacFont.ui(10.5, weight: .semibold)))
                    .foregroundStyle(theme.ink3)
            }
            Spacer(minLength: 8)
            if isWorks {
                SearchPagerView(theme: theme, appState: appState, model: model)
            } else {
                CollectionBookmarksPagerView(theme: theme, appState: appState, model: model)
            }
        }
        .padding(.horizontal, 10)
        .frame(height: 36)
        .frame(maxWidth: .infinity)
        .background(theme.surface)
        .overlay(alignment: .bottom) { theme.line.frame(height: 1) }
    }
}

/// Results list for the scopes that don't produce works: tag, user, and
/// collection hits from the library search. Rows navigate — a tag or
/// collection opens its works (flipping to the Works tab's results), a
/// user opens the author view.
struct ScopeResultsView: View {
    @Bindable var theme: AppTheme
    @Bindable var appState: AppState
    @Bindable var model: MacAppModel

    var body: some View {
        let search = model.search
        ScrollView {
            VStack(spacing: 0) {
                if appState.isSearching {
                    ProgressView()
                        .controlSize(.small)
                        .frame(maxWidth: .infinity, minHeight: 240)
                } else {
                    resultRows(search)
                }
            }
        }
    }

    @ViewBuilder
    private func resultRows(_ search: MacSearchModel) -> some View {
        switch search.scope {
        case .tags:
            if search.tagHits.isEmpty { emptyState }
            ForEach(Array(search.tagHits.enumerated()), id: \.offset) { _, hit in
                row(icon: "tag", title: hit.name, sub: Self.tagTypeLabel(hit.tagType)) {
                    search.startTagQuery(hit.name, appState: appState)
                }
            }
        case .users:
            if search.userHits.isEmpty { emptyState }
            ForEach(search.userHits, id: \.self) { username in
                row(icon: "person", title: username, sub: "AO3 user") {
                    model.openAuthorProfile(username)
                }
            }
        case .collections:
            if search.collectionHits.isEmpty { emptyState }
            ForEach(search.collectionHits, id: \.name) { collection in
                collectionRow(collection)
            }
        case .bookmarks:
            let hits = search.filteredBookmarkHits
            if hits.isEmpty {
                if search.bookmarkListFilter.isActive && !search.bookmarkHits.isEmpty {
                    EmptyStateMac(
                        theme: theme, icon: "line.3.horizontal.decrease.circle",
                        title: "No bookmarks match the filter",
                        message: "Adjust or clear the header filter to see the results again.")
                        .frame(minHeight: 240)
                } else {
                    emptyState
                }
            }
            ForEach(Array(hits.enumerated()), id: \.offset) { _, hit in
                bookmarkRow(hit)
            }
        case .works:
            EmptyView() // works results render in the works table, not here
        }
    }

    private var emptyState: some View {
        let library = model.search.searchLibraryOnly
        return EmptyStateMac(
            theme: theme, icon: "magnifyingglass",
            title: library ? "No matches in your library" : "No matches on AO3",
            message: library
                ? "Only what the app has already cached is searched. Browse or fetch more to grow the library."
                : "Nothing on AO3 matched these criteria.")
            .frame(minHeight: 240)
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

    private func row(icon: String, title: String, sub: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: icon)
                    .font(.system(size: 13, weight: .medium))
                    .frame(width: 18)
                    .foregroundStyle(theme.accent)
                VStack(alignment: .leading, spacing: 1) {
                    Text(title)
                        .font(Font(MacFont.ui(14, weight: .semibold)))
                        .foregroundStyle(theme.ink)
                        .lineLimit(1)
                    Text(sub)
                        .font(Font(MacFont.ui(12)))
                        .foregroundStyle(theme.ink3)
                }
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(theme.ink3)
            }
            .padding(.init(top: 11, leading: 16, bottom: 11, trailing: 16))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .overlay(alignment: .bottom) { theme.line.frame(height: 1) }
    }

    private func collectionRow(_ collection: UCollection) -> some View {
        Button {
            model.search.startCollectionQuery(collection.name,
                                              title: collection.title,
                                              workCount: collection.workCount,
                                              bookmarkedCount: collection.bookmarkedCount,
                                              fromHitList: true,
                                              appState: appState)
        } label: {
            HStack(spacing: 12) {
                Image(systemName: "square.grid.2x2")
                    .font(.system(size: 13, weight: .medium))
                    .frame(width: 18)
                    .foregroundStyle(theme.accent)
                VStack(alignment: .leading, spacing: 2) {
                    Text(collection.title)
                        .font(Font(MacFont.ui(14, weight: .semibold)))
                        .foregroundStyle(theme.ink)
                        .lineLimit(1)
                    Text(collectionMeta(collection))
                        .font(Font(MacFont.ui(12)))
                        .foregroundStyle(theme.ink3)
                        .lineLimit(1)
                    if !collection.summary.isEmpty {
                        Text(collection.summary)
                            .font(Font(MacFont.ui(12)))
                            .foregroundStyle(theme.ink2)
                            .lineLimit(2)
                    }
                }
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(theme.ink3)
            }
            .padding(.init(top: 11, leading: 16, bottom: 11, trailing: 16))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .overlay(alignment: .bottom) { theme.line.frame(height: 1) }
    }

    /// A bookmark hit laid out like a work list item: bookmarked-by/date in
    /// the top-right corner, tag pill lists (work tags, then the
    /// bookmarker's accented tags), kudos/words/chapters meta at the
    /// bottom. Clicking opens the work; clicking a tag block expands it.
    private func bookmarkRow(_ hit: UBookmarkHit) -> some View {
        Button {
            model.openWorkByID(String(hit.work.id))
        } label: {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: "bookmark")
                    .font(.system(size: 13, weight: .medium))
                    .frame(width: 18)
                    .foregroundStyle(theme.accent)
                    .padding(.top, 2)
                VStack(alignment: .leading, spacing: 4) {
                    // Top-right corner (the work row's dates slot) splits
                    // across the first two lines so it never grows taller
                    // than the title+byline block: bookmarked-by rides the
                    // title line, the date rides the author line.
                    HStack(alignment: .top, spacing: 10) {
                        Text(hit.work.title)
                            .font(Font(MacFont.ui(14, weight: .semibold)))
                            .foregroundStyle(theme.ink)
                            .lineLimit(2)
                        Spacer(minLength: 8)
                        HStack(spacing: 5) {
                            if hit.rec {
                                Text("REC")
                                    .font(Font(MacFont.ui(9.5, weight: .bold)))
                                    .kerning(0.5)
                                    .foregroundStyle(theme.onAccent)
                                    .padding(.horizontal, 5)
                                    .padding(.vertical, 1.5)
                                    .background(theme.accent)
                                    .clipShape(Capsule())
                            }
                            Text(hit.bookmarker.isEmpty
                                ? "Bookmarked" : "Bookmarked by \(hit.bookmarker)")
                                .lineLimit(1)
                        }
                        .font(Font(MacFont.ui(10, weight: .medium)))
                        .foregroundStyle(theme.ink3)
                        .padding(.top, 2)
                    }
                    if !authorLine(hit.work).isEmpty || !hit.dateBookmarked.isEmpty {
                        HStack(alignment: .firstTextBaseline, spacing: 10) {
                            Text(authorLine(hit.work))
                                .font(Font(MacFont.ui(12)))
                                .foregroundStyle(theme.ink3)
                                .lineLimit(1)
                            Spacer(minLength: 8)
                            if !hit.dateBookmarked.isEmpty {
                                Text(hit.dateBookmarked)
                                    .font(Font(MacFont.ui(10, weight: .medium)))
                                    .foregroundStyle(theme.ink3)
                            }
                        }
                    }
                    if !fandomLine(hit.work).isEmpty {
                        Text(fandomLine(hit.work))
                            .font(Font(MacFont.ui(12)))
                            .foregroundStyle(theme.ink3)
                            .lineLimit(1)
                    }
                    let workTags = Self.sortedTags(
                        hit.work.relationships + hit.work.characters + hit.work.tags)
                    if !workTags.isEmpty {
                        CollapsibleTagPills(theme: theme, tags: workTags)
                    }
                    if !hit.tags.isEmpty {
                        CollapsibleTagPills(theme: theme, tags: Self.sortedTags(hit.tags),
                                            accented: true)
                    }
                    if !hit.note.isEmpty {
                        Text(hit.note)
                            .font(Font(MacFont.ui(12)))
                            .foregroundStyle(theme.ink2)
                            .lineLimit(3)
                    }
                    Text(bookmarkWorkMeta(hit.work))
                        .font(Font(MacFont.ui(11, weight: .medium)))
                        .foregroundStyle(theme.ink3)
                        .lineLimit(1)
                        .padding(.top, 2)
                }
                Image(systemName: "chevron.right")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(theme.ink3)
                    .padding(.top, 2)
            }
            .padding(.init(top: 11, leading: 16, bottom: 11, trailing: 16))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .overlay(alignment: .bottom) { theme.line.frame(height: 1) }
    }

    /// Alphabetical, like the work list item's tag block.
    private static func sortedTags(_ tags: [String]) -> [String] {
        tags.sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
    }

    private func authorLine(_ work: UWorkSummary) -> String {
        work.authors.isEmpty ? "" : "by \(work.authors.joined(separator: ", "))"
    }

    private func fandomLine(_ work: UWorkSummary) -> String {
        work.fandoms.prefix(2).joined(separator: ", ")
    }

    /// The work row's bottom meta line: kudos, words, chapter progress.
    private func bookmarkWorkMeta(_ work: UWorkSummary) -> String {
        let total = work.complete ? String(work.totalChapters) : "?"
        return "♥ \(Fmt.k(Int(work.kudos)))   \(Fmt.k(Int(work.wordCount))) words   \(work.chapterCount)/\(total)"
    }

    private func collectionMeta(_ collection: UCollection) -> String {
        var parts = [collection.workCount == 1 ? "1 work" : "\(collection.workCount) works"]
        if collection.bookmarkedCount > 0 {
            parts.append(collection.bookmarkedCount == 1
                ? "1 bookmarked item" : "\(collection.bookmarkedCount) bookmarked items")
        }
        if !collection.collectionType.isEmpty { parts.append(collection.collectionType) }
        if !collection.maintainers.isEmpty {
            parts.append("by \(collection.maintainers.joined(separator: ", "))")
        }
        return parts.joined(separator: " · ")
    }
}
