import SwiftUI

/// The Library tab: search the works already in the library, across
/// sources. The shared fields come first; under them, conditions the
/// reader adds from whatever each source records, each with a list of
/// the values the library holds now (or bounds, for a number).
struct LibrarySearchFormView: View {
    @Bindable var theme: AppTheme
    @Bindable var appState: AppState
    @Bindable var model: MacAppModel

    var body: some View {
        let _ = theme.uiFontScale
        @Bindable var form = model.librarySearch
        SearchFormScroll {
            VStack(alignment: .leading, spacing: 16) {
                VStack(alignment: .leading, spacing: 5) {
                    caption("Search Library")
                    HStack(spacing: 7) {
                        Image(systemName: "text.magnifyingglass")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(theme.ink3)
                        TextField("Title, summary, author or tag…", text: $form.text)
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

                labelled("Sources") {
                    FlowLayout(spacing: 6) {
                        chip("All sources", on: form.sources.isEmpty) { form.sources = [] }
                        ForEach(form.sourceCounts, id: \.source) { source in
                            chip("\(source.name) · \(source.works)", on: form.sources.contains(source.source)) {
                                form.toggleSource(source.source)
                            }
                        }
                    }
                }

                LazyVGrid(columns: [GridItem(.adaptive(minimum: 220, maximum: 360), spacing: 18, alignment: .topLeading)],
                          alignment: .leading, spacing: 14) {
                    labelled("Title") {
                        textBox("words in the title", $form.title)
                    }
                    tagField("Creator", "creator", $form.author)
                    tagField("Fandoms", "fandom", $form.fandoms)
                    tagField("Characters", "character", $form.characters)
                    tagField("Relationships", "relationship", $form.relationships)
                    tagField("Additional Tags", "freeform", $form.tags)
                    labelled("Date Updated") {
                        textBox("< 2 weeks ago, > 2024-01-01", $form.updated)
                    }
                    labelled("Date Published") {
                        textBox("< 1 year ago, 2024-06", $form.published)
                    }
                    labelled("Language") {
                        DropdownControl(theme: theme,
                                        title: form.language.isEmpty ? "Any" : form.language,
                                        options: [("Any", "", form.language.isEmpty)]
                                            + form.languages.map { ($0, $0, $0 == form.language) },
                                        onPick: { form.language = $0 })
                    }
                    labelled("Completion") {
                        DropdownControl(theme: theme,
                                        title: form.complete == "T" ? "Complete" : (form.complete == "F" ? "In progress" : "Any"),
                                        options: [("Any", "", form.complete.isEmpty), ("Complete", "T", form.complete == "T"),
                                                  ("In progress", "F", form.complete == "F")],
                                        onPick: { form.complete = $0 })
                    }
                    labelled("Words") {
                        rangeBox($form.words)
                    }
                    labelled("Downloaded") {
                        Toggle("Fully downloaded only", isOn: $form.fullyDownloaded)
                            .toggleStyle(.checkbox)
                            .font(Font(MacFont.ui(11.5)))
                            .foregroundStyle(theme.ink2)
                    }
                }

                labelled("Rating") {
                    FlowLayout(spacing: 6) {
                        ForEach(LibrarySearchModel.ratingLabels, id: \.self) { label in
                            chip(label, on: form.ratings.contains(label)) { form.toggleRating(label) }
                        }
                    }
                }

                Divider().padding(.vertical, 2)

                conditions
            }
            .padding(20)
        }
        .task { form.load(appState) }
    }

    // MARK: Conditions

    private var conditions: some View {
        let form = model.librarySearch
        return VStack(alignment: .leading, spacing: 14) {
            caption("Source Fields")
            ForEach(form.rows) { row in
                conditionRow(row)
                    .revealedInForm(when: row.options.map(\.value) + row.values, onAppear: true)
            }
            if form.fields.isEmpty {
                Text("Nothing in the library carries a source field yet.")
                    .font(Font(MacFont.ui(11.5)))
                    .foregroundStyle(theme.ink3)
            } else {
                DropdownControl(theme: theme, title: "Add a field…",
                                options: form.fields.enumerated().map { (form.fieldTitle($0.element), String($0.offset), false) },
                                onPick: { picked in
                                    guard let index = Int(picked), form.fields.indices.contains(index) else { return }
                                    form.addRow(form.fields[index], appState: appState)
                                })
                    .frame(maxWidth: 280)
                Text("A field belongs to one source and limits that source's works. With fields from several sources, each source's works answer their own fields, and works from all of them are found. Sources with no field are left out unless picked above.")
                    .font(Font(MacFont.ui(11)))
                    .foregroundStyle(theme.ink3)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func conditionRow(_ row: LibrarySearchModel.Row) -> some View {
        let form = model.librarySearch
        return VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 8) {
                Text(form.fieldTitle(row.field))
                    .font(Font(MacFont.ui(12.5, weight: .semibold)))
                    .foregroundStyle(theme.ink)
                Spacer()
                Button { form.removeRow(row.id) } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(theme.ink3)
                        .frame(width: 20, height: 20)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Remove this field")
            }
            switch row.field.input {
            case .range:
                rangeBox(Binding(get: { row.range }, set: { form.setRange(row.id, $0) }))
                    .frame(maxWidth: 280)
                if !row.field.high.isEmpty {
                    Text(row.field.low == row.field.high
                         ? "In your library: \(row.field.high)"
                         : "In your library: \(row.field.low) to \(row.field.high)")
                        .font(Font(MacFont.ui(11)))
                        .foregroundStyle(theme.ink3)
                }
            case .contains:
                textBox("contains…", Binding(get: { row.contains }, set: { form.setContains(row.id, $0) }))
                    .frame(maxWidth: 280)
            case .choice:
                FlowLayout(spacing: 6) {
                    ForEach(row.options, id: \.value) { option in
                        chip("\(option.value) · \(option.works)", on: row.values.contains(option.value)) {
                            form.toggleValue(row.id, option.value)
                        }
                    }
                }
            case .search:
                if !row.values.isEmpty {
                    FlowLayout(spacing: 6) {
                        ForEach(row.values, id: \.self) { value in
                            chip(value, on: true) { form.toggleValue(row.id, value) }
                        }
                    }
                }
                textBox("type to find a value", Binding(get: { row.filter }, set: { form.setFilter(row.id, $0, appState: appState) }))
                    .frame(maxWidth: 280)
                let open = row.options.filter { !row.values.contains($0.value) }
                if open.isEmpty {
                    Text(row.options.isEmpty ? "No value in the library matches." : "Every listed value is picked.")
                        .font(Font(MacFont.ui(11)))
                        .foregroundStyle(theme.ink3)
                } else {
                    FlowLayout(spacing: 6) {
                        ForEach(open, id: \.value) { option in
                            chip("\(option.value) · \(option.works)", on: false) { form.toggleValue(row.id, option.value) }
                        }
                    }
                    if row.options.count >= Int(LibrarySearchModel.optionLimit) {
                        Text("Showing the \(LibrarySearchModel.optionLimit) most used — type to find others.")
                            .font(Font(MacFont.ui(11)))
                            .foregroundStyle(theme.ink3)
                    }
                }
            }
        }
        .padding(12)
        .background(theme.surface2.opacity(0.5))
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(theme.line, lineWidth: 1))
    }

    // MARK: Pieces

    /// A tag-name field: typing looks names up in the library's tags
    /// cache, picked names become chips. Never goes to a site.
    private func tagField(_ label: String, _ tagType: String, _ value: Binding<String>) -> some View {
        TagTokenField(theme: theme, appState: appState, label: label, tagType: tagType,
                      value: value, localOnly: true)
    }

    private func chip(_ title: String, on: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(Font(MacFont.ui(11.5, weight: .semibold)))
                .foregroundStyle(on ? theme.onAccent : theme.ink2)
                .lineLimit(1)
                .padding(.horizontal, 9)
                .padding(.vertical, 4)
                .background(on ? theme.accent : theme.surface2)
                .clipShape(Capsule())
        }
        .buttonStyle(.plain)
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

    /// One box for a typed range; outlined in red while what is typed
    /// does not read as one.
    private func rangeBox(_ text: Binding<String>) -> some View {
        let wrong = LibrarySearchModel.rangeIsWrong(text.wrappedValue)
        return textBox(LibrarySearchModel.rangeExample, text)
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(wrong ? Color.red.opacity(0.7) : .clear, lineWidth: 1))
            .help("A range: >1500, >=1500, <100000, 1500-10000, or one exact amount. 10k and 2m work too.")
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
            .onSubmit { model.librarySearch.run(model.search, appState: appState) }
    }
}
