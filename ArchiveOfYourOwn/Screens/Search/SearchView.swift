import SwiftUI

struct SearchView: View {
    @Environment(AppTheme.self) private var theme
    @Environment(AppState.self) private var state
    @Environment(NavigationState.self) private var nav

    @State private var formFields: [UFormField] = []
    @State private var fieldValues: [String: String] = [:]
    @State private var checkboxValues: [String: Set<String>] = [:]
    @State private var isLoadingForm = false
    @State private var formError: String?
    @State private var hasSearched = false
    @State private var showFilters = false
    @State private var searchTask: Task<Void, Never>?
    @State private var savedSearches: [USavedSearch] = []
    @State private var showSaveDialog = false
    @State private var saveSearchName = ""

    private var textFields: [UFormField] {
        formFields.filter { $0.fieldType == "text" }
    }

    private var selectFields: [UFormField] {
        formFields.filter { $0.fieldType == "select" }
    }

    private var checkboxFields: [UFormField] {
        formFields.filter { $0.fieldType == "checkboxes" }
    }

    private var primaryField: UFormField? {
        textFields.first { $0.name.contains("[query]") }
    }

    private var filterFields: [UFormField] {
        formFields.filter { f in
            f.name != primaryField?.name && f.fieldType != "hidden"
        }
    }

    private var displayedWorks: [Work] {
        var results = state.searchResults
        if state.hideExplicit {
            results = results.filter { $0.rating != .explicit }
        }
        return results
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                masthead

                if !savedSearches.isEmpty && !hasSearched {
                    savedSearchesSection
                        .padding(.horizontal, theme.pad)
                        .padding(.bottom, 12)
                }

                if isLoadingForm {
                    NetworkLoadingView(message: "Loading search form…", task: state.searchTask, operation: "search") {
                        state.searchTask.cancel()
                        isLoadingForm = false
                    }
                } else if let error = formError {
                    NetworkErrorView(message: error, onRetry: {
                        formError = nil
                        Task { await loadForm() }
                    })
                } else if formFields.isEmpty {
                    EmptyStateView(
                        systemImage: "magnifyingglass",
                        title: "Search AO3",
                        subtitle: "Loading search options…"
                    )
                    .padding(.top, 60)
                } else {
                    searchForm
                        .padding(.horizontal, theme.pad)

                    searchResults
                }
            }
            .padding(.bottom, 32)
        }
        .background { ThemeBackgroundView() }
        .task {
            if formFields.isEmpty && state.bridge.isInitialized {
                await loadForm()
            }
            savedSearches = state.bridge.getSavedSearches()
        }
        .alert("Save Search", isPresented: $showSaveDialog) {
            TextField("Search name", text: $saveSearchName)
            Button("Save") { saveCurrentSearch() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Give this search a name to find it quickly later.")
        }
        .onChange(of: state.bridge.isInitialized) { _, initialized in
            if initialized && formFields.isEmpty {
                Task { await loadForm() }
            }
        }
    }

    // MARK: - Masthead

    private var masthead: some View {
        HStack {
            Text("Search")
                .font(Typography.browseTitle())
                .foregroundStyle(theme.ink)
            Spacer()
            if !formFields.isEmpty {
                Button {
                    Task { await fetchFormFromNetwork() }
                } label: {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(theme.ink3)
                        .frame(width: 32, height: 32)
                }
                .buttonStyle(IconButtonPressStyle())
                .disabled(isLoadingForm)
            }
            PrivacyPillView { nav.presentedSheet = .privacy }
        }
        .padding(.horizontal, theme.pad)
        .padding(.top, 8)
        .padding(.bottom, 12)
    }

    // MARK: - Dynamic Form

    private var searchForm: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let primary = primaryField {
                dynamicField(primary)
            }

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

            if showFilters {
                VStack(alignment: .leading, spacing: 12) {
                    ForEach(filterFields, id: \.name) { field in
                        dynamicField(field)
                    }
                }
                .transition(.opacity.combined(with: .move(edge: .top)))
            }

            Button { performSearch() } label: {
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
        }
    }

    @ViewBuilder
    private func dynamicField(_ field: UFormField) -> some View {
        switch field.fieldType {
        case "text":
            textFieldView(field)
        case "select":
            selectFieldView(field)
        case "checkboxes":
            checkboxGroupView(field)
        case "radio":
            radioGroupView(field)
        default:
            EmptyView()
        }
    }

    private func textFieldView(_ field: UFormField) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            if !field.label.isEmpty {
                Text(field.label)
                    .font(Typography.uiSmall())
                    .foregroundStyle(theme.ink3)
                    .textCase(.uppercase)
            }

            TextField(field.placeholder.isEmpty ? field.label : field.placeholder,
                      text: binding(for: field.name))
                .font(.custom("HankenGrotesk", size: 15).weight(.medium))
                .foregroundStyle(theme.ink)
                .padding(.horizontal, 12)
                .frame(height: 42)
                .background(theme.surface2)
                .clipShape(RoundedRectangle(cornerRadius: 10))
                .onSubmit { performSearch() }
        }
    }

    private func selectFieldView(_ field: UFormField) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            if !field.label.isEmpty {
                Text(field.label)
                    .font(Typography.uiSmall())
                    .foregroundStyle(theme.ink3)
                    .textCase(.uppercase)
            }

            Menu {
                ForEach(field.options, id: \.value) { option in
                    Button(option.label.isEmpty ? "(any)" : option.label) {
                        fieldValues[field.name] = option.value
                    }
                }
            } label: {
                HStack {
                    let currentValue = fieldValues[field.name] ?? ""
                    let currentLabel = field.options.first { $0.value == currentValue }?.label ?? "(any)"
                    Text(currentLabel.isEmpty ? "(any)" : currentLabel)
                        .font(.custom("HankenGrotesk", size: 14).weight(.medium))
                        .foregroundStyle(theme.ink)
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
    }

    private func checkboxGroupView(_ field: UFormField) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            if !field.label.isEmpty {
                Text(field.label)
                    .font(Typography.uiSmall())
                    .foregroundStyle(theme.ink3)
                    .textCase(.uppercase)
            }

            FlowLayoutSimple(spacing: 6) {
                ForEach(field.options, id: \.value) { option in
                    let selected = checkboxValues[field.name]?.contains(option.value) ?? false
                    Button {
                        var set = checkboxValues[field.name] ?? []
                        if selected { set.remove(option.value) }
                        else { set.insert(option.value) }
                        checkboxValues[field.name] = set
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

    private func radioGroupView(_ field: UFormField) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            if !field.label.isEmpty {
                Text(field.label)
                    .font(Typography.uiSmall())
                    .foregroundStyle(theme.ink3)
                    .textCase(.uppercase)
            }

            Menu {
                ForEach(field.options, id: \.value) { option in
                    Button(option.label.isEmpty ? "(any)" : option.label) {
                        fieldValues[field.name] = option.value
                    }
                }
            } label: {
                HStack {
                    let currentValue = fieldValues[field.name] ?? field.options.first { $0.selected }?.value ?? ""
                    let currentLabel = field.options.first { $0.value == currentValue }?.label ?? field.options.first?.label ?? "(any)"
                    Text(currentLabel.isEmpty ? "(any)" : currentLabel)
                        .font(.custom("HankenGrotesk", size: 14).weight(.medium))
                        .foregroundStyle(theme.ink)
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
    }

    // MARK: - Results

    @ViewBuilder
    private var searchResults: some View {
        if state.isSearching {
            NetworkLoadingView(message: "Searching…", task: state.searchTask, operation: "search") {
                state.searchTask.cancel()
            }
        } else if hasSearched && displayedWorks.isEmpty && state.searchError == nil {
            EmptyStateView(
                systemImage: "magnifyingglass",
                title: "No results",
                subtitle: "Try different search terms or filters."
            )
            .padding(.top, 40)
        } else if let error = state.searchError, hasSearched {
            NetworkErrorView(message: error, onRetry: {
                state.searchError = nil
                performSearch()
            })
        } else if hasSearched {
            HStack {
                Text("\(displayedWorks.count) results")
                    .font(Typography.uiBody())
                    .foregroundStyle(theme.ink2)
                Spacer()
                Button {
                    showSaveDialog = true
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "bookmark")
                            .font(.system(size: 12, weight: .semibold))
                        Text("Save")
                            .font(Typography.uiSmall())
                    }
                    .foregroundStyle(theme.accent)
                }
            }
            .padding(.horizontal, theme.pad)
            .padding(.top, 12)
            .padding(.bottom, 8)

            LazyVStack(spacing: theme.rowGap) {
                ForEach(displayedWorks) { work in
                    WorkCardView(
                        work: work,
                        blurExplicit: state.hideExplicit && work.rating == .explicit,
                        onTap: { nav.openWork(work.id) }
                    )
                }

                if !state.isSearching {
                    Button {
                        Task { await state.searchAO3More() }
                    } label: {
                        Text("Load more")
                            .font(Typography.smallButtonLabel())
                            .foregroundStyle(theme.accent)
                            .frame(maxWidth: .infinity)
                            .frame(height: 44)
                            .background(
                                RoundedRectangle(cornerRadius: Radius.button)
                                    .stroke(theme.line, lineWidth: 1)
                            )
                    }
                    .buttonStyle(ButtonPressStyle())
                }

                if state.isSearching && !displayedWorks.isEmpty {
                    NetworkLoadingView(message: "Loading more...", task: state.searchTask, operation: "search") {
                        state.searchTask.cancel()
                    }
                }
            }
            .padding(.horizontal, theme.pad)
        }
    }

    // MARK: - Data

    private func binding(for name: String) -> Binding<String> {
        Binding(
            get: { fieldValues[name] ?? "" },
            set: { fieldValues[name] = $0 }
        )
    }

    private func loadForm() async {
        if let cached = Self.loadCachedForm() {
            formFields = cached
            return
        }
        await fetchFormFromNetwork()
    }

    private func fetchFormFromNetwork() async {
        isLoadingForm = true
        formError = nil
        do {
            let fields = try await state.retryOnTimeout(task: state.searchTask, using: state.bridge) {
                try await self.state.bridge.fetchSearchForm()
            }
            formFields = fields
            Self.cacheForm(fields)
        } catch {
            if !state.searchTask.isCancelled && !"\(error)".contains("cancelled") {
                formError = error.localizedDescription
            }
        }
        isLoadingForm = false
    }

    private static func cacheForm(_ fields: [UFormField]) {
        let data: [[String: Any]] = fields.map { f in
            [
                "name": f.name, "label": f.label, "fieldType": f.fieldType,
                "placeholder": f.placeholder,
                "options": f.options.map { ["value": $0.value, "label": $0.label, "selected": $0.selected] }
            ]
        }
        if let json = try? JSONSerialization.data(withJSONObject: data) {
            UserDefaults.standard.set(json, forKey: "cachedSearchForm")
        }
    }

    private static func loadCachedForm() -> [UFormField]? {
        guard let json = UserDefaults.standard.data(forKey: "cachedSearchForm"),
              let arr = try? JSONSerialization.jsonObject(with: json) as? [[String: Any]] else { return nil }
        let fields = arr.compactMap { dict -> UFormField? in
            guard let name = dict["name"] as? String,
                  let label = dict["label"] as? String,
                  let fieldType = dict["fieldType"] as? String,
                  let placeholder = dict["placeholder"] as? String,
                  let optArr = dict["options"] as? [[String: Any]] else { return nil }
            let options = optArr.compactMap { o -> UFormOption? in
                guard let value = o["value"] as? String,
                      let label = o["label"] as? String,
                      let selected = o["selected"] as? Bool else { return nil }
                return UFormOption(value: value, label: label, selected: selected)
            }
            return UFormField(name: name, label: label, fieldType: fieldType, placeholder: placeholder, options: options)
        }
        return fields.isEmpty ? nil : fields
    }

    private func performSearch() {
        hasSearched = true
        searchTask?.cancel()

        // Build key-value pairs from all dynamic form fields
        var keys: [String] = []
        var values: [String] = []

        for (name, value) in fieldValues {
            if !value.isEmpty {
                keys.append(name)
                values.append(value)
            }
        }

        for (name, selectedValues) in checkboxValues {
            for value in selectedValues {
                keys.append(name)
                values.append(value)
            }
        }

        searchTask = Task {
            await state.searchAO3Raw(keys: keys, values: values)
        }
    }

    // MARK: - Saved Searches

    private var savedSearchesSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("SAVED SEARCHES")
                .font(Typography.sectionHeader())
                .tracking(0.08 * 13)
                .foregroundStyle(theme.ink3)

            ForEach(savedSearches, id: \.id) { search in
                HStack {
                    Button {
                        loadSavedSearch(search)
                    } label: {
                        HStack(spacing: 8) {
                            Image(systemName: "magnifyingglass")
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundStyle(theme.accent)
                            Text(search.name)
                                .font(Typography.uiBody())
                                .foregroundStyle(theme.ink)
                                .lineLimit(1)
                        }
                    }

                    Spacer()

                    Button {
                        state.bridge.deleteSavedSearch(search.id)
                        savedSearches = state.bridge.getSavedSearches()
                    } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(theme.ink3)
                    }
                }
                .padding(.vertical, 6)
            }
        }
    }

    private func currentParamsJson() -> String {
        var dict: [String: Any] = [:]
        dict["fields"] = fieldValues.filter { !$0.value.isEmpty }
        dict["checkboxes"] = checkboxValues.mapValues { Array($0) }.filter { !$0.value.isEmpty }
        return (try? JSONSerialization.data(withJSONObject: dict).base64EncodedString()) ?? ""
    }

    private func loadSavedSearch(_ search: USavedSearch) {
        guard let data = Data(base64Encoded: search.paramsJson),
              let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }

        if let fields = dict["fields"] as? [String: String] {
            fieldValues = fields
        }
        if let checkboxes = dict["checkboxes"] as? [String: [String]] {
            checkboxValues = checkboxes.mapValues { Set($0) }
        }
        performSearch()
    }

    private func saveCurrentSearch() {
        guard !saveSearchName.isEmpty else { return }
        let json = currentParamsJson()
        state.bridge.saveSearch(name: saveSearchName, paramsJson: json)
        savedSearches = state.bridge.getSavedSearches()
        saveSearchName = ""
        showSaveDialog = false
    }
}

private struct FlowLayoutSimple: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        var x: CGFloat = 0
        var y: CGFloat = 0
        var rowHeight: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x + size.width > maxWidth && x > 0 {
                x = 0
                y += rowHeight + spacing
                rowHeight = 0
            }
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }

        return CGSize(width: maxWidth, height: y + rowHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX
        var y = bounds.minY
        var rowHeight: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x + size.width > bounds.maxX && x > bounds.minX {
                x = bounds.minX
                y += rowHeight + spacing
                rowHeight = 0
            }
            subview.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
    }
}

#Preview {
    SearchView()
        .environment(AppTheme())
        .environment(AppState())
        .environment(NavigationState())
}
