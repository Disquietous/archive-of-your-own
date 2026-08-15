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
        case .works, .bookmarks:
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
