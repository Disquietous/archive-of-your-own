import SwiftUI

/// The full AO3 search form, rendered from the archive's own form fields —
/// header of the list pane's Search section. Results render in the works
/// table beneath.
struct SearchFormView: View {
    @Bindable var theme: AppTheme
    @Bindable var appState: AppState
    @Bindable var model: MacAppModel

    private var search: MacSearchModel { model.search }

    var body: some View {
        @Bindable var search = model.search
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                queryField
                Button {
                    search.performSearch(appState)
                } label: {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(theme.onAccent)
                        .frame(width: 34, height: 34)
                        .background(theme.accent)
                        .clipShape(RoundedRectangle(cornerRadius: 9))
                }
                .buttonStyle(.plain)
                .help("Search")
            }

            if search.isLoadingForm {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Loading search options from the archive…")
                        .font(Font(MacFont.ui(11.5)))
                        .foregroundStyle(theme.ink3)
                }
            } else if let error = search.formError {
                HStack(spacing: 8) {
                    Text(error)
                        .font(Font(MacFont.ui(11.5)))
                        .foregroundStyle(Color(hex: "CE514D"))
                        .lineLimit(2)
                    Button("Retry") {
                        Task { await search.loadFormIfNeeded(appState) }
                    }
                    .buttonStyle(.plain)
                    .font(Font(MacFont.ui(11.5, weight: .bold)))
                    .foregroundStyle(theme.accent)
                }
            } else if !search.filterFields.isEmpty {
                filtersDisclosure
                if search.showFilters {
                    ScrollView {
                        filterControls
                    }
                    .frame(maxHeight: 320)
                }
            }
        }
        .padding(.init(top: 12, leading: 16, bottom: 12, trailing: 16))
        .frame(maxWidth: .infinity, alignment: .leading)
        .overlay(alignment: .bottom) { theme.line.frame(height: 1) }
    }

    private var queryField: some View {
        @Bindable var search = model.search
        return HStack(spacing: 7) {
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

    private var filtersDisclosure: some View {
        @Bindable var search = model.search
        return HStack {
            Button {
                withAnimation(.easeInOut(duration: 0.18)) { search.showFilters.toggle() }
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 9, weight: .bold))
                        .rotationEffect(.degrees(search.showFilters ? 90 : 0))
                    Text("Filters")
                        .font(Font(MacFont.ui(12, weight: .bold)))
                    if activeFilterCount > 0 {
                        Text("\(activeFilterCount)")
                            .font(Font(MacFont.ui(10, weight: .bold)))
                            .foregroundStyle(theme.onAccent)
                            .padding(.horizontal, 5)
                            .frame(minWidth: 16, minHeight: 16)
                            .background(theme.accent)
                            .clipShape(Capsule())
                    }
                }
                .foregroundStyle(theme.ink2)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            Spacer()
            if activeFilterCount > 0 {
                Button("Clear") { search.clearFilters() }
                    .buttonStyle(.plain)
                    .font(Font(MacFont.ui(11.5, weight: .semibold)))
                    .foregroundStyle(theme.ink3)
            }
        }
    }

    private var activeFilterCount: Int {
        let fieldCount = search.fieldValues.filter { $0.key != search.primaryField?.name && !$0.value.isEmpty }.count
        let checkboxCount = search.checkboxValues.reduce(0) { $0 + $1.value.count }
        return fieldCount + checkboxCount
    }

    private var filterControls: some View {
        @Bindable var search = model.search
        return VStack(alignment: .leading, spacing: 12) {
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
        .padding(.top, 4)
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
