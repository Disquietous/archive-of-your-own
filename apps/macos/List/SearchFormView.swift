import SwiftUI

/// The Search section's middle pane: criteria only. Fields are AO3's own
/// search form (scraped and stored in the database); results render in the
/// reading pane with full pagination.
struct SearchFormView: View {
    @Bindable var theme: AppTheme
    @Bindable var appState: AppState
    @Bindable var model: MacAppModel

    var body: some View {
        let _ = theme.uiFontScale  // track app text size so fonts refresh live
        @Bindable var search = model.search
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                queryField

                if search.isLoadingForm {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text("Loading criteria from the archive…")
                            .font(Font(MacFont.ui(11.5)))
                            .foregroundStyle(theme.ink3)
                    }
                } else if let error = search.formError {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(error)
                            .font(Font(MacFont.ui(11.5)))
                            .foregroundStyle(Color(hex: "CE514D"))
                        Button("Retry") {
                            Task { await search.scrapeForm(appState) }
                        }
                        .buttonStyle(.plain)
                        .font(Font(MacFont.ui(11.5, weight: .bold)))
                        .foregroundStyle(theme.accent)
                    }
                } else if search.formFields.isEmpty {
                    Text("Search criteria haven’t been loaded yet. Use the ↻ button above to fetch them from AO3.")
                        .font(Font(MacFont.ui(12)))
                        .foregroundStyle(theme.ink3)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    if search.activeFilterCount > 0 {
                        HStack {
                            Text("\(search.activeFilterCount) filters active")
                                .font(Font(MacFont.ui(11.5, weight: .semibold)))
                                .foregroundStyle(theme.accent)
                            Spacer()
                            Button("Clear") { search.clearFilters() }
                                .buttonStyle(.plain)
                                .font(Font(MacFont.ui(11.5, weight: .semibold)))
                                .foregroundStyle(theme.ink3)
                        }
                    }
                    ForEach(search.filterFields, id: \.name) { field in
                        switch field.fieldType {
                        case "select":
                            selectControl(field)
                        case "checkboxes":
                            checkboxControl(field)
                        default:
                            textControl(field)
                        }
                    }
                }
            }
            .padding(16)
        }
    }

    private var queryField: some View {
        @Bindable var search = model.search
        return VStack(alignment: .leading, spacing: 5) {
            Text("QUERY")
                .font(Font(MacFont.ui(10.5, weight: .bold)))
                .kerning(0.6)
                .foregroundStyle(theme.ink3)
            HStack(spacing: 7) {
                Image(systemName: "text.magnifyingglass")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(theme.ink3)
                TextField("Any field — title, author, tags…", text: $search.queryText)
                    .textFieldStyle(.plain)
                    .font(Font(MacFont.ui(13)))
                    .foregroundStyle(theme.ink)
                    .onSubmit { search.performSearch(appState) }
            }
            .padding(.horizontal, 10)
            .frame(height: 34)
            .background(theme.surface)
            .clipShape(RoundedRectangle(cornerRadius: 9))
            .overlay(RoundedRectangle(cornerRadius: 9).stroke(theme.line, lineWidth: 1))
        }
    }

    private func fieldLabel(_ field: UFormField) -> some View {
        Text(field.label.uppercased())
            .font(Font(MacFont.ui(10.5, weight: .bold)))
            .kerning(0.6)
            .foregroundStyle(theme.ink3)
    }

    private func selectControl(_ field: UFormField) -> some View {
        @Bindable var search = model.search
        let current = search.fieldValues[field.name] ?? ""
        let currentLabel = field.options.first { $0.value == current }?.label
            ?? field.options.first?.label ?? "Any"
        return VStack(alignment: .leading, spacing: 5) {
            fieldLabel(field)
            Menu {
                ForEach(field.options, id: \.value) { option in
                    Button(option.label) {
                        search.fieldValues[field.name] = option.value
                    }
                }
            } label: {
                HStack {
                    Text(currentLabel)
                        .font(Font(MacFont.ui(12.5, weight: .medium)))
                        .foregroundStyle(theme.ink)
                    Spacer()
                    Image(systemName: "chevron.up.chevron.down")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(theme.ink3)
                }
                .padding(.horizontal, 10)
                .frame(height: 30)
                .background(theme.surface)
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(theme.line, lineWidth: 1))
            }
            .menuStyle(.borderlessButton)
        }
    }

    private func checkboxControl(_ field: UFormField) -> some View {
        @Bindable var search = model.search
        return VStack(alignment: .leading, spacing: 5) {
            fieldLabel(field)
            FlowLayout(spacing: 6) {
                ForEach(field.options, id: \.value) { option in
                    let on = search.checkboxValues[field.name]?.contains(option.value) ?? false
                    Button {
                        var set = search.checkboxValues[field.name] ?? []
                        if on { set.remove(option.value) } else { set.insert(option.value) }
                        search.checkboxValues[field.name] = set
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

    private func textControl(_ field: UFormField) -> some View {
        @Bindable var search = model.search
        return VStack(alignment: .leading, spacing: 5) {
            fieldLabel(field)
            TextField(field.placeholder.isEmpty ? field.label : field.placeholder,
                      text: Binding(
                        get: { search.fieldValues[field.name] ?? "" },
                        set: { search.fieldValues[field.name] = $0 }
                      ))
                .textFieldStyle(.plain)
                .font(Font(MacFont.ui(12.5)))
                .foregroundStyle(theme.ink)
                .padding(.horizontal, 10)
                .frame(height: 30)
                .background(theme.surface)
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(theme.line, lineWidth: 1))
                .onSubmit { search.performSearch(appState) }
        }
    }
}
