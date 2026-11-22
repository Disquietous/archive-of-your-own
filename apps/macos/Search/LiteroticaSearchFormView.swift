import SwiftUI

/// The Literotica tab: the site's advanced story search, laid out for
/// that site. Search words and what they are looked for in, the date
/// window, sort, author name, the form's three "only stories which are"
/// boxes, and its categories as chips (none picked = all categories). Go
/// packs it into the generic query the core hands to the adapter.
struct LiteroticaSearchFormView: View {
    @Bindable var theme: AppTheme
    @Bindable var appState: AppState
    @Bindable var model: MacAppModel

    var body: some View {
        let _ = theme.uiFontScale
        @Bindable var form = model.literoticaSearch
        SearchFormScroll {
            VStack(alignment: .leading, spacing: 16) {
                queryField

                if form.activeFilterCount > 0 {
                    HStack {
                        Text(form.activeFilterCount == 1 ? "1 limit active" : "\(form.activeFilterCount) limits active")
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
                    labelled("Search Only") {
                        dropdown("where", value: form.scope) { form.scope = $0 }
                    }
                    labelled("Find Stories From the Last") {
                        HStack(spacing: 6) {
                            dropdown("period", value: form.period) { form.period = $0 }
                            dropdown("time_direction", value: form.timeDirection) { form.timeDirection = $0 }
                                .frame(maxWidth: 120)
                                .disabled(form.period == "all")
                                .opacity(form.period == "all" ? 0.5 : 1)
                        }
                    }
                    labelled("Sort Results By") {
                        HStack(spacing: 6) {
                            DropdownControl(theme: theme,
                                            title: form.schema?.sort?.columns.first { $0.value == form.sortColumn }?.label ?? form.sortColumn,
                                            options: (form.schema?.sort?.columns ?? []).map { ($0.label, $0.value, $0.value == form.sortColumn) },
                                            onPick: { form.sortColumn = $0 })
                            DropdownControl(theme: theme,
                                            title: form.schema?.sort?.directions.first { $0.value == form.sortDirection }?.label ?? form.sortDirection,
                                            options: (form.schema?.sort?.directions ?? []).map { ($0.label, $0.value, $0.value == form.sortDirection) },
                                            onPick: { form.sortDirection = $0 })
                        }
                    }
                    labelled("Author's Name") {
                        textBox("stories by this author", $form.author)
                    }
                    labelled("Only Stories Which Are") {
                        VStack(alignment: .leading, spacing: 6) {
                            checkbox("Editor's choice", $form.editorsChoice)
                            checkbox("Contest winners", $form.winner)
                            checkbox("Most popular", $form.popular)
                        }
                    }
                }

                Divider().padding(.vertical, 2)

                labelled("Categories") {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(form.categories.isEmpty ? "Searching all categories" : "Searching only the picked categories")
                            .font(Font(MacFont.ui(10.5)))
                            .foregroundStyle(theme.ink3)
                        FlowLayout(spacing: 6) {
                            ForEach(form.options("categories"), id: \.value) { option in
                                let picked = form.categories.contains(option.value)
                                Button { form.toggleCategory(option.value) } label: {
                                    Text(option.label)
                                        .font(Font(MacFont.ui(11.5, weight: .semibold)))
                                        .foregroundStyle(picked ? theme.onAccent : theme.ink2)
                                        .padding(.horizontal, 9)
                                        .padding(.vertical, 4)
                                        .background(picked ? theme.accent : theme.surface2)
                                        .clipShape(Capsule())
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                }

                Text("Searches English stories. A story that is part of a series is listed as its series.")
                    .font(Font(MacFont.ui(11)))
                    .foregroundStyle(theme.ink3)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(20)
        }
        .task { form.loadIfNeeded(appState) }
    }

    // MARK: Pieces

    private var queryField: some View {
        @Bindable var form = model.literoticaSearch
        return VStack(alignment: .leading, spacing: 5) {
            caption("Search for Stories")
            HStack(spacing: 7) {
                Image(systemName: "text.magnifyingglass")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(theme.ink3)
                TextField("Search stories…", text: $form.text)
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

    /// One of the form's fixed lists.
    private func dropdown(_ key: String, value: String, onPick: @escaping (String) -> Void) -> some View {
        let form = model.literoticaSearch
        let options: [(label: String, value: String, checked: Bool)] = form.options(key).map { ($0.label, $0.value, $0.value == value) }
        return DropdownControl(theme: theme, title: form.label(key, value), options: options, onPick: onPick)
    }

    private func checkbox(_ title: String, _ isOn: Binding<Bool>) -> some View {
        Toggle(title, isOn: isOn)
            .toggleStyle(.checkbox)
            .font(Font(MacFont.ui(11.5)))
            .foregroundStyle(theme.ink2)
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
            .onSubmit { model.literoticaSearch.run(model.search, appState: appState) }
    }
}
