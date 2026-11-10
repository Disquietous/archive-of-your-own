import SwiftUI

/// The ScribbleHub tab: the Series Finder, laid out for that site. Title,
/// genre and content-warning chips (click once to include, twice to
/// exclude, with the site's AND/OR match), story status and sort up top;
/// the finder's "Advance" block (numeric ranges, last update, fandom,
/// tags, contest) behind a disclosure. Go packs it into the generic query
/// the core hands to the ScribbleHub adapter.
struct ScribbleHubSearchFormView: View {
    @Bindable var theme: AppTheme
    @Bindable var appState: AppState
    @Bindable var model: MacAppModel

    var body: some View {
        let _ = theme.uiFontScale
        @Bindable var form = model.scribbleHubSearch
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                titleField

                if form.activeFilterCount > 0 {
                    HStack {
                        Text(form.activeFilterCount == 1 ? "1 filter active" : "\(form.activeFilterCount) filters active")
                            .font(Font(MacFont.ui(11.5, weight: .semibold)))
                            .foregroundStyle(theme.accent)
                        Spacer()
                        Button("Clear") { form.clear() }
                            .buttonStyle(.plain)
                            .font(Font(MacFont.ui(11.5, weight: .semibold)))
                            .foregroundStyle(theme.ink3)
                    }
                }

                LazyVGrid(columns: [GridItem(.adaptive(minimum: 220, maximum: 360), spacing: 18, alignment: .topLeading)],
                          alignment: .leading, spacing: 14) {
                    labelled("Story Status") {
                        DropdownControl(theme: theme,
                                        title: form.status.isEmpty ? "All" : form.label("status", form.status),
                                        options: [("All", "", form.status.isEmpty)] + form.options("status").map { ($0.label, $0.value, $0.value == form.status) },
                                        onPick: { form.status = $0 })
                    }
                    labelled("Sort By") {
                        HStack(spacing: 6) {
                            DropdownControl(theme: theme,
                                            title: form.schema?.sort?.columns.first { $0.value == form.sortColumn }?.label ?? form.sortColumn,
                                            options: (form.schema?.sort?.columns ?? []).map { ($0.label, $0.value, $0.value == form.sortColumn) },
                                            onPick: { form.sortColumn = $0 })
                            DropdownControl(theme: theme,
                                            title: form.sortDirection == "asc" ? "Ascending" : "Descending",
                                            options: [("Descending", "desc", form.sortDirection == "desc"), ("Ascending", "asc", form.sortDirection == "asc")],
                                            onPick: { form.sortDirection = $0 })
                                .frame(maxWidth: 140)
                        }
                    }
                }

                pickGroup("Genre", key: "genres", picks: $form.genres)
                pickGroup("Content Warning", key: "content_warnings", picks: $form.contentWarnings)

                Divider().padding(.vertical, 2)

                Button {
                    withAnimation(.easeInOut(duration: 0.15)) { form.showAdvanced.toggle() }
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: form.showAdvanced ? "chevron.down" : "chevron.right")
                            .font(.system(size: 9, weight: .bold))
                        Text("ADVANCED")
                            .font(Font(MacFont.ui(11, weight: .bold)))
                            .kerning(0.8)
                    }
                    .foregroundStyle(theme.ink2)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)

                if form.showAdvanced {
                    advanced
                }
            }
            .padding(20)
        }
        .task { form.loadIfNeeded(appState) }
    }

    // MARK: Pieces

    private var titleField: some View {
        @Bindable var form = model.scribbleHubSearch
        return VStack(alignment: .leading, spacing: 5) {
            caption("Title Contains")
            HStack(spacing: 7) {
                Image(systemName: "text.magnifyingglass")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(theme.ink3)
                TextField("Title contains…", text: $form.title)
                    .textFieldStyle(.plain)
                    .font(Font(MacFont.ui(13)))
                    .foregroundStyle(theme.ink)
                    .onSubmit { form.run(model.search, appState: appState) }
            }
            .padding(.horizontal, 10)
            .frame(height: 34)
            .background(theme.surface)
            .clipShape(RoundedRectangle(cornerRadius: 9))
            .overlay(RoundedRectangle(cornerRadius: 9).stroke(theme.line, lineWidth: 1))
        }
    }

    private var advanced: some View {
        @Bindable var form = model.scribbleHubSearch
        return VStack(alignment: .leading, spacing: 16) {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 220, maximum: 320), spacing: 18, alignment: .topLeading)],
                      alignment: .leading, spacing: 14) {
                boundsField("Chapters", $form.chapters)
                boundsField("Chapters per Week", $form.chaptersPerWeek)
                boundsField("Favorites", $form.favorites)
                boundsField("Ratings (0–5)", $form.rating)
                boundsField("Number of Ratings", $form.ratingCount)
                boundsField("Readers", $form.readers)
                boundsField("Reviews", $form.reviews)
                boundsField("Pages", $form.pages)
                boundsField("Pageviews (thousands)", $form.pageviews)
                boundsField("Total Words (thousands)", $form.totalWords)
                labelled("Last Update") {
                    HStack(spacing: 6) {
                        textBox("from yyyy-mm-dd", $form.updatedFrom)
                        Text("–").foregroundStyle(theme.ink3)
                        textBox("to yyyy-mm-dd", $form.updatedTo)
                    }
                }
                labelled("Contest") {
                    DropdownControl(theme: theme,
                                    title: form.contest.isEmpty ? "Any" : form.label("contest", form.contest),
                                    options: [("Any", "", form.contest.isEmpty)] + form.options("contest").map { ($0.label, $0.value, $0.value == form.contest) },
                                    onPick: { form.contest = $0 })
                }
            }

            TagTokenField(theme: theme, appState: appState, label: "Fandom", tagType: "fandom",
                          value: $form.fandoms,
                          remote: (site: "ScribbleHub", lookup: { term in
                              try await appState.bridge.searchAutocomplete(
                                  source: ScribbleHubSearchModel.sourceID, key: "fandom", prefix: term).map(\.label)
                          }))

            labelled("Tags") {
                VStack(alignment: .leading, spacing: 8) {
                    matchRow(picks: $form.tags, hint: "Pick a tag to include it; click its chip to exclude it instead")
                    TagPicker(theme: theme, options: form.options("tags"), picks: $form.tags)
                }
            }
        }
    }

    /// A finder option set as chips cycling none → include → exclude,
    /// with the site's AND/OR match for the included ones.
    private func pickGroup(_ title: String, key: String, picks: Binding<ScribbleHubSearchModel.Picks>) -> some View {
        @Bindable var form = model.scribbleHubSearch
        return labelled(title) {
            VStack(alignment: .leading, spacing: 8) {
                matchRow(picks: picks, hint: "Click once to include, twice to exclude")
                FlowLayout(spacing: 6) {
                    ForEach(form.options(key), id: \.value) { option in
                        let included = picks.wrappedValue.include.contains(option.value)
                        let excluded = picks.wrappedValue.exclude.contains(option.value)
                        Button { picks.wrappedValue.cycle(option.value) } label: {
                            HStack(spacing: 3) {
                                if excluded { Image(systemName: "minus").font(.system(size: 8, weight: .bold)) }
                                Text(option.label).strikethrough(excluded)
                            }
                            .font(Font(MacFont.ui(11.5, weight: .semibold)))
                            .foregroundStyle(included ? theme.onAccent : (excluded ? theme.ink3 : theme.ink2))
                            .padding(.horizontal, 9)
                            .padding(.vertical, 4)
                            .background(included ? theme.accent : theme.surface2)
                            .overlay(Capsule().stroke(excluded ? theme.ink3 : .clear, lineWidth: 1))
                            .clipShape(Capsule())
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
    }

    private func matchRow(picks: Binding<ScribbleHubSearchModel.Picks>, hint: String) -> some View {
        HStack(spacing: 8) {
            Text("Match")
                .font(Font(MacFont.ui(11)))
                .foregroundStyle(theme.ink3)
            DropdownControl(theme: theme,
                            title: picks.wrappedValue.mode == "and" ? "AND" : "OR",
                            options: [("AND", "and", picks.wrappedValue.mode == "and"), ("OR", "or", picks.wrappedValue.mode == "or")],
                            onPick: { picks.wrappedValue.mode = $0 })
                .frame(maxWidth: 110)
            Text(hint)
                .font(Font(MacFont.ui(10.5)))
                .foregroundStyle(theme.ink3)
        }
    }

    private func boundsField(_ title: String, _ bounds: Binding<ScribbleHubSearchModel.Bounds>) -> some View {
        labelled(title) {
            HStack(spacing: 6) {
                textBox("min", bounds.min)
                Text("–").foregroundStyle(theme.ink3)
                textBox("max", bounds.max)
            }
        }
    }

    private func caption(_ text: String) -> some View {
        Text(text.uppercased())
            .font(Font(MacFont.ui(10.5, weight: .bold)))
            .kerning(0.6)
            .foregroundStyle(theme.ink3)
    }

    private func labelled<Content: View>(_ title: String, @ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            caption(title)
            content()
        }
    }

    private func textBox(_ placeholder: String, _ text: Binding<String>) -> some View {
        TextField(placeholder, text: text)
            .textFieldStyle(.plain)
            .font(Font(MacFont.ui(12.5)))
            .foregroundStyle(theme.ink)
            .padding(.horizontal, 10)
            .frame(height: 30)
            .background(theme.surface)
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(theme.line, lineWidth: 1))
            .onSubmit { model.scribbleHubSearch.run(model.search, appState: appState) }
    }
}

/// The finder's tag list (hundreds of fixed tags): a filter box narrows
/// the list, chosen tags show as chips above it. A suggestion click
/// includes the tag; a chip click cycles include → exclude → off.
private struct TagPicker: View {
    @Bindable var theme: AppTheme
    let options: [FieldOption]
    @Binding var picks: ScribbleHubSearchModel.Picks

    @State private var input = ""
    @FocusState private var focused: Bool

    private var term: String { input.trimmingCharacters(in: .whitespaces) }

    private var matches: [FieldOption] {
        guard !term.isEmpty else { return [] }
        return Array(options
            .filter { $0.label.localizedCaseInsensitiveContains(term) && !picks.include.contains($0.value) && !picks.exclude.contains($0.value) }
            .prefix(12))
    }

    var body: some View {
        let chosen = options.filter { picks.include.contains($0.value) || picks.exclude.contains($0.value) }
        VStack(alignment: .leading, spacing: 6) {
            VStack(alignment: .leading, spacing: 6) {
                if !chosen.isEmpty {
                    FlowLayout(spacing: 5) {
                        ForEach(chosen, id: \.value) { option in
                            let excluded = picks.exclude.contains(option.value)
                            Button { picks.cycle(option.value) } label: {
                                HStack(spacing: 3) {
                                    if excluded { Image(systemName: "minus").font(.system(size: 8, weight: .bold)) }
                                    Text(option.label).strikethrough(excluded)
                                    Image(systemName: "xmark").font(.system(size: 7, weight: .bold)).opacity(0.7)
                                }
                                .font(Font(MacFont.ui(11.5, weight: .semibold)))
                                .foregroundStyle(excluded ? theme.ink3 : theme.onAccent)
                                .padding(.horizontal, 9)
                                .padding(.vertical, 4)
                                .background(excluded ? theme.surface2 : theme.accent)
                                .overlay(Capsule().stroke(excluded ? theme.ink3 : .clear, lineWidth: 1))
                                .clipShape(Capsule())
                            }
                            .buttonStyle(.plain)
                            .help(excluded ? "Excluded — click to remove" : "Included — click to exclude")
                        }
                    }
                }
                TextField("Type to find tags…", text: $input)
                    .textFieldStyle(.plain)
                    .font(Font(MacFont.ui(12.5)))
                    .foregroundStyle(theme.ink)
                    .focused($focused)
                    .onSubmit {
                        if let first = matches.first {
                            picks.cycle(first.value)
                            input = ""
                        }
                    }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(theme.surface)
            .clipShape(RoundedRectangle(cornerRadius: 9))
            .overlay(RoundedRectangle(cornerRadius: 9).stroke(focused ? theme.accent : theme.line, lineWidth: 1))

            if focused && !matches.isEmpty {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(matches, id: \.value) { option in
                        Button {
                            picks.cycle(option.value)
                            input = ""
                        } label: {
                            Text(option.label)
                                .font(Font(MacFont.ui(12)))
                                .foregroundStyle(theme.ink)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.horizontal, 10)
                                .padding(.vertical, 4)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.vertical, 4)
                .background(theme.surface)
                .clipShape(RoundedRectangle(cornerRadius: 9))
                .overlay(RoundedRectangle(cornerRadius: 9).stroke(theme.line, lineWidth: 1))
            }
        }
    }
}
