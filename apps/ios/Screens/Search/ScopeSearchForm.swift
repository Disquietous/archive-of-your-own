import SwiftUI

/// The criteria form for the non-works search scopes (Collections,
/// Bookmarks, Tags, Users): one query field — Bookmarks/Tags/Users search
/// by name, while Collections adds the full sort/filter criteria AO3's
/// /collections index accepts and Bookmarks mirrors /bookmarks/search.
/// The footer explains what the source toggle means for this scope.
/// Mirrors the macOS `ScopeSearchFormView`.
struct ScopeSearchForm: View {
    @Environment(AppTheme.self) private var theme
    @Environment(AppState.self) private var state
    @Environment(SearchModel.self) private var search

    @FocusState private var focused: Bool

    private var placeholder: String {
        switch search.scope {
        case .works: ""
        case .collections: "Filter by title…"
        case .bookmarks: "Title, author, tag, or summary…"
        case .tags: "Tag name…"
        case .users: "Username…"
        }
    }

    var body: some View {
        @Bindable var search = search
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(theme.ink3)
                TextField(placeholder, text: $search.scopeQuery)
                    .textFieldStyle(.plain)
                    .font(.custom("HankenGrotesk", size: 15).weight(.medium))
                    .foregroundStyle(theme.ink)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                    .focused($focused)
                    .submitLabel(.search)
                    .onSubmit { search.performScopedSearch(state) }
            }
            .padding(.horizontal, 12)
            .frame(height: 42)
            .background(theme.surface2)
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10)
                .stroke(focused ? theme.accent : theme.line, lineWidth: 1))

            if search.scope == .collections {
                collectionsCriteria
            }

            if search.scope == .bookmarks {
                bookmarksCriteria
            }

            if let notice = search.scopeNotice {
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "info.circle")
                        .font(.system(size: 13, weight: .medium))
                    Text(notice)
                        .font(Typography.uiSmall())
                        .fixedSize(horizontal: false, vertical: true)
                }
                .foregroundStyle(theme.ink2)
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(theme.accentSoft)
                .clipShape(RoundedRectangle(cornerRadius: 10))
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
        .task(id: search.scope) {
            // The bookmarks form borrows the works form's language options —
            // cache-only, never a fetch of its own.
            if search.scope == .bookmarks {
                search.loadCachedFormIfAvailable(state)
            }
        }
    }

    // MARK: - Collections criteria (mirrors AO3's /collections filter form)

    private static let triState: [(value: String, label: String)] =
        [("", "Either"), ("true", "Yes"), ("false", "No")]

    @ViewBuilder
    private var collectionsCriteria: some View {
        @Bindable var search = search
        // Any-type tag tokens ("" tagType): suggestions come from the whole
        // library tag cache, like every other tag field in the app.
        TagTokenField(label: "Tags", tagType: "", value: $search.collectionTags)
        pillRow("Multifandom", options: Self.triState, selection: $search.collectionMultifandom)
        pillRow("Closed", options: Self.triState, selection: $search.collectionClosed)
        pillRow("Moderated", options: Self.triState, selection: $search.collectionModerated)
        pillRow("Collection type",
                options: [("", "Any"), ("GiftExchange", "Gift Exchange"),
                          ("PromptMeme", "Prompt Meme"), ("no_challenge", "No Challenge")],
                selection: $search.collectionChallengeType)
        pillRow("Sort by",
                options: [("created_at", "Date Created"), ("title.keyword", "Title"),
                          ("bookmarked_items_count", "Bookmarked Items"), ("works_count", "Works")],
                selection: $search.collectionSortColumn)
        pillRow("Sort direction",
                options: [("desc", "Descending"), ("asc", "Ascending")],
                selection: $search.collectionSortDirection)
    }

    // MARK: - Bookmarks criteria (mirrors AO3's /bookmarks/search form)

    /// The query field above doubles as the form's "any field on work"
    /// query; everything else follows the site's three fieldsets —
    /// bookmarked item, the bookmark itself, and sort.
    @ViewBuilder
    private var bookmarksCriteria: some View {
        @Bindable var search = search
        TagTokenField(label: "Work tags", tagType: "", value: $search.bookmarkWorkTags)
        pillRow("Type", options: [("", "Any"), ("Work", "Work"), ("Series", "Series"),
                                  ("External Work", "External Work")],
                selection: $search.bookmarkType)
        textRow("Word count", placeholder: "e.g. >10000 or 1000-5000", text: $search.bookmarkWordCount)
        languageRow
        textRow("Date updated", placeholder: "e.g. < 2 weeks ago or 2025", text: $search.bookmarkDateUpdated)

        sectionHeader("Bookmark")
        textRow("Any field on bookmark", placeholder: "Notes, tags…", text: $search.bookmarkQuery)
        TagTokenField(label: "Bookmarker's tags", tagType: "", value: $search.bookmarkerTags)
        textRow("Bookmarker", placeholder: "Username…", text: $search.bookmarkBookmarker)
        textRow("Notes", placeholder: "Text in the bookmarker's notes…", text: $search.bookmarkNotes)
        togglePillRow("Bookmark type", toggles: [
            ("Rec", $search.bookmarkRecOnly),
            ("With notes", $search.bookmarkWithNotesOnly)])
        textRow("Date bookmarked", placeholder: "e.g. < 1 month ago", text: $search.bookmarkDate)

        sectionHeader("Search")
        pillRow("Sort by",
                options: [("", "Best Match"), ("created_at", "Date Bookmarked"),
                          ("bookmarkable_date", "Date Updated"), ("word_count", "Word Count")],
                selection: $search.bookmarkSortColumn)
    }

    /// The work-language menu, populated from the scraped works form's
    /// language select (the two forms share AO3's language list). Hidden
    /// until the works criteria have been scraped at least once.
    @ViewBuilder
    private var languageRow: some View {
        if let field = search.formFields.first(where: { $0.name.contains("[language_id]") }) {
            let current = search.bookmarkLanguage
            let title = field.options.first { $0.value == current }
                .map { $0.label.trimmingCharacters(in: .whitespaces) }
                .flatMap { $0.isEmpty ? nil : $0 } ?? "Any"
            VStack(alignment: .leading, spacing: 5) {
                criteriaLabel("Work language")
                Menu {
                    ForEach(field.options, id: \.value) { option in
                        let label = option.label.trimmingCharacters(in: .whitespaces)
                        Button {
                            search.bookmarkLanguage = option.value
                        } label: {
                            if option.value == current {
                                Label(label.isEmpty ? "Any" : label, systemImage: "checkmark")
                            } else {
                                Text(label.isEmpty ? "Any" : label)
                            }
                        }
                    }
                } label: {
                    SearchDropdownLabel(title: title)
                }
            }
        }
    }

    private func sectionHeader(_ title: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Divider().padding(.top, 4)
            Text(title.uppercased())
                .font(Typography.sectionHeader())
                .tracking(0.08 * 13)
                .foregroundStyle(theme.ink2)
        }
    }

    /// A labeled single-line text criterion; Return runs the search like
    /// the query field.
    private func textRow(_ title: String, placeholder: String, text: Binding<String>) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            criteriaLabel(title)
            TextField(placeholder, text: text)
                .textFieldStyle(.plain)
                .font(.custom("HankenGrotesk", size: 14).weight(.medium))
                .foregroundStyle(theme.ink)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
                .submitLabel(.search)
                .onSubmit { search.performScopedSearch(state) }
                .padding(.horizontal, 12)
                .frame(height: 42)
                .background(theme.surface2)
                .clipShape(RoundedRectangle(cornerRadius: 10))
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
                        chipLabel(toggle.label, on: on)
                    }
                    .buttonStyle(ChipPressStyle())
                }
            }
        }
    }

    private func criteriaLabel(_ text: String) -> some View {
        Text(text.uppercased())
            .font(.custom("HankenGrotesk", size: 10.5).weight(.bold))
            .tracking(0.6)
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
                        chipLabel(option.label, on: on)
                    }
                    .buttonStyle(ChipPressStyle())
                }
            }
        }
    }

    private func chipLabel(_ text: String, on: Bool) -> some View {
        Text(text)
            .font(.custom("HankenGrotesk", size: 12).weight(.semibold))
            .foregroundStyle(on ? theme.onAccent : theme.ink2)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: Radius.chip)
                    .fill(on ? theme.accent : theme.surface)
            )
            .overlay(
                RoundedRectangle(cornerRadius: Radius.chip)
                    .stroke(on ? theme.accent : theme.line, lineWidth: 1)
            )
    }
}

/// The themed label for a dropdown-style Menu in the search forms: the
/// value on a bordered field with a chevron pair at the right.
struct SearchDropdownLabel: View {
    @Environment(AppTheme.self) private var theme

    let title: String

    var body: some View {
        HStack {
            Text(title)
                .font(.custom("HankenGrotesk", size: 14).weight(.medium))
                .foregroundStyle(theme.ink)
                .lineLimit(1)
            Spacer()
            Image(systemName: "chevron.up.chevron.down")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(theme.ink3)
        }
        .padding(.horizontal, 12)
        .frame(height: 42)
        .background(theme.surface2)
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }
}

/// What the source toggle means: the same explanatory footer every form
/// carries on macOS.
struct SearchSourceFooter: View {
    @Environment(AppTheme.self) private var theme
    @Environment(SearchModel.self) private var search

    var body: some View {
        Text(search.searchLibraryOnly
            ? "Searching your library — everything the app has already fetched and cached. Nothing leaves the device."
            : "Searching AO3 — results come from the archive over Tor.")
            .font(Typography.uiSmall())
            .foregroundStyle(theme.ink3)
            .fixedSize(horizontal: false, vertical: true)
    }
}
