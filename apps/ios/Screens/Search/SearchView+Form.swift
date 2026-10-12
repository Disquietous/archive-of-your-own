import SwiftUI

extension SearchView {
    // MARK: - Form

    var formScroll: some View {
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
    var worksForm: some View {
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

    var queryField: some View {
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
    func fieldControl(_ field: UFormField) -> some View {
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

    func fieldLabel(_ text: String) -> some View {
        Text(text.uppercased())
            .font(.custom("HankenGrotesk", size: 10.5).weight(.bold))
            .tracking(0.6)
            .foregroundStyle(theme.ink3)
    }

    /// AO3 selects mark their no-filter option with a blank label — surface
    /// those as "Any" so the control always shows a value.
    static func optionTitle(_ label: String) -> String {
        let trimmed = label.trimmingCharacters(in: .whitespaces)
        return trimmed.isEmpty ? "Any" : trimmed
    }

    func textFieldView(_ field: UFormField) -> some View {
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

    func selectFieldView(_ field: UFormField, defaultValue: String) -> some View {
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

    func checkboxGroupView(_ field: UFormField) -> some View {
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
    static let rangeFieldSuffixes = [
        "[word_count]", "[hits]", "[kudos_count]", "[comments_count]", "[bookmarks_count]",
    ]

    static func placeholderHint(for field: UFormField) -> String {
        if !field.placeholder.isEmpty { return field.placeholder }
        if rangeFieldSuffixes.contains(where: { field.name.hasSuffix($0) }) {
            return ">1000 · <500 · 100-5000"
        }
        if field.name.hasSuffix("[revised_at]") {
            return "e.g. 2024, or < 2 weeks ago"
        }
        return field.label
    }

    func binding(for name: String) -> Binding<String> {
        Binding(
            get: { search.fieldValues[name] ?? "" },
            set: { search.fieldValues[name] = $0 }
        )
    }
}
