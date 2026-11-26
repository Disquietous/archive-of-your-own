import SwiftUI

/// The Wattpad tab: the site's story search, laid out for that site.
/// Search words, tags, and the three filters the site puts beside its
/// results (length in parts, last updated, completed only). Go packs it
/// into the generic query the core hands to the adapter.
struct WattpadSearchFormView: View {
    @Bindable var theme: AppTheme
    @Bindable var appState: AppState
    @Bindable var model: MacAppModel

    var body: some View {
        let _ = theme.uiFontScale
        @Bindable var form = model.wattpadSearch
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
                    labelled("Tags") {
                        textBox("tags, separated by spaces or commas", $form.tags)
                    }
                    labelled("Length") {
                        dropdown("length", value: form.length) { form.length = $0 }
                    }
                    labelled("Last Updated") {
                        dropdown("updated", value: form.updated) { form.updated = $0 }
                    }
                    labelled("Content") {
                        Toggle("Only show completed stories", isOn: $form.completeOnly)
                            .toggleStyle(.checkbox)
                            .font(Font(MacFont.ui(11.5)))
                            .foregroundStyle(theme.ink2)
                    }
                }

                Text("The site lists mature stories only to a signed-in account whose content setting allows them. Results come in the site's own order; it offers no sort.")
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
        @Bindable var form = model.wattpadSearch
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
        let form = model.wattpadSearch
        let options: [(label: String, value: String, checked: Bool)] = form.options(key).map { ($0.label, $0.value, $0.value == value) }
        return DropdownControl(theme: theme, title: form.label(key, value), options: options, onPick: onPick)
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
            .onSubmit { model.wattpadSearch.run(model.search, appState: appState) }
    }
}
