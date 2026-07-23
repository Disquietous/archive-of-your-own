import SwiftUI

/// Filter popover for work lists: free text over title/author/summary plus
/// selected-tag chips fed by a type-ahead field (same pattern as the Fandoms
/// follow field) suggesting from the tags present in the current list.
struct WorkListFilterView: View {
    @Bindable var theme: AppTheme
    @Bindable var model: MacAppModel
    let section: MacAppModel.Section

    private var filter: Binding<MacAppModel.WorkListFilter> {
        Binding(get: { model.workListFilter(for: section) },
                set: { model.workListFilters[section] = $0 })
    }

    var body: some View {
        let _ = theme.uiFontScale  // track app text size so fonts refresh live
        VStack(alignment: .leading, spacing: 10) {
            header("Filter Works", clearEnabled: filter.wrappedValue.isActive) {
                model.workListFilters[section] = nil
            }
            filterField("Title, author, or summary", text: filter.text)
            HStack(spacing: 8) {
                filterField("Kudos (e.g. >1000)", text: filter.kudos)
                filterField("Words (e.g. <50000)", text: filter.words)
            }

            TokenFilterSection(theme: theme, label: "FANDOM",
                               placeholder: "Type to add a fandom…",
                               selected: filter.fandoms,
                               allOptions: model.availableFandoms(for: section))
            TokenFilterSection(theme: theme, label: "TAGS",
                               placeholder: "Type to add a tag…",
                               selected: filter.tags,
                               allOptions: model.availableTags(for: section))
        }
        .padding(14)
        .frame(width: 320)
        .background(theme.surface)
    }
}

/// Chips + type-ahead selector over a fixed option pool (the values present
/// in the current list) — the filter dialog's fandom and tag sections.
private struct TokenFilterSection: View {
    @Bindable var theme: AppTheme
    let label: String
    let placeholder: String
    @Binding var selected: Set<String>
    let allOptions: [String]

    @State private var input = ""

    private var term: String {
        input.trimmingCharacters(in: .whitespaces)
    }

    private var suggestions: [String] {
        guard !term.isEmpty else { return [] }
        return allOptions
            .filter { $0.localizedCaseInsensitiveContains(term) && !selected.contains($0) }
            .prefix(8)
            .map { $0 }
    }

    var body: some View {
        Text(label)
            .font(Font(MacFont.ui(10, weight: .bold)))
            .kerning(0.6)
            .foregroundStyle(theme.ink3)
        if !selected.isEmpty {
            FlowLayout(spacing: 5) {
                ForEach(selected.sorted(), id: \.self) { value in
                    chip(value)
                }
            }
        }
        TextField(placeholder, text: $input)
            .textFieldStyle(.plain)
            .font(Font(MacFont.ui(12.5)))
            .foregroundStyle(theme.ink)
            .padding(.horizontal, 9)
            .frame(height: 30)
            .background(theme.surface2)
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .onSubmit {
                if let first = suggestions.first { add(first) }
            }
        if !suggestions.isEmpty {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(suggestions, id: \.self) { value in
                    suggestionRow(value)
                }
            }
            .padding(.vertical, 4)
            .background(theme.surface2)
            .clipShape(RoundedRectangle(cornerRadius: 8))
        }
    }

    private func add(_ value: String) {
        selected.insert(value)
        input = ""
    }

    private func chip(_ value: String) -> some View {
        HStack(spacing: 4) {
            Text(value)
                .font(Font(MacFont.ui(11.5, weight: .medium)))
                .foregroundStyle(theme.ink2)
                .lineLimit(1)
            Button {
                selected.remove(value)
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(theme.ink3)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(theme.surface2)
        .clipShape(Capsule())
    }

    private func suggestionRow(_ value: String) -> some View {
        Button {
            add(value)
        } label: {
            Text(value)
                .font(Font(MacFont.ui(12)))
                .foregroundStyle(theme.ink)
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 9)
                .padding(.vertical, 4)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

/// Filter popover with a single targeted field (Authors: username;
/// Fandoms/Following: name).
struct SingleFieldFilterView: View {
    @Bindable var theme: AppTheme
    let title: String
    let placeholder: String
    @Binding var text: String

    var body: some View {
        let _ = theme.uiFontScale
        VStack(alignment: .leading, spacing: 10) {
            header(theme: theme, title: title,
                   clearEnabled: !text.isEmpty) { text = "" }
            FilterTextField(theme: theme, placeholder: placeholder, text: $text)
        }
        .padding(14)
        .frame(width: 280)
        .background(theme.surface)
    }
}

/// Inbox filter: sender, work, and message text as separate fields.
struct InboxFilterView: View {
    @Bindable var theme: AppTheme
    @Bindable var model: MacAppModel

    private var anyActive: Bool {
        !model.inboxFilterAuthor.isEmpty || !model.inboxFilterWork.isEmpty || !model.inboxFilterText.isEmpty
    }

    var body: some View {
        let _ = theme.uiFontScale
        VStack(alignment: .leading, spacing: 10) {
            header(theme: theme, title: "Filter Inbox", clearEnabled: anyActive) {
                model.inboxFilterAuthor = ""
                model.inboxFilterWork = ""
                model.inboxFilterText = ""
            }
            FilterTextField(theme: theme, placeholder: "From user", text: $model.inboxFilterAuthor)
            FilterTextField(theme: theme, placeholder: "Work title", text: $model.inboxFilterWork)
            FilterTextField(theme: theme, placeholder: "Message text", text: $model.inboxFilterText)
        }
        .padding(14)
        .frame(width: 280)
        .background(theme.surface)
    }
}

// MARK: - Shared pieces

private extension WorkListFilterView {
    func header(_ title: String, clearEnabled: Bool, onClear: @escaping () -> Void) -> some View {
        ListFilterHeader(theme: theme, title: title, clearEnabled: clearEnabled, onClear: onClear)
    }

    func filterField(_ placeholder: String, text: Binding<String>) -> some View {
        FilterTextField(theme: theme, placeholder: placeholder, text: text)
    }
}

private func header(theme: AppTheme, title: String, clearEnabled: Bool,
                    onClear: @escaping () -> Void) -> some View {
    ListFilterHeader(theme: theme, title: title, clearEnabled: clearEnabled, onClear: onClear)
}

private struct ListFilterHeader: View {
    @Bindable var theme: AppTheme
    let title: String
    let clearEnabled: Bool
    let onClear: () -> Void

    var body: some View {
        HStack {
            Text(title)
                .font(Font(MacFont.ui(13, weight: .bold)))
                .foregroundStyle(theme.ink)
            Spacer()
            Button("Clear", action: onClear)
                .buttonStyle(.plain)
                .font(Font(MacFont.ui(11.5, weight: .semibold)))
                .foregroundStyle(clearEnabled ? theme.accent : theme.ink3)
                .disabled(!clearEnabled)
        }
    }
}

private struct FilterTextField: View {
    @Bindable var theme: AppTheme
    let placeholder: String
    @Binding var text: String

    var body: some View {
        TextField(placeholder, text: $text)
            .textFieldStyle(.plain)
            .font(Font(MacFont.ui(12.5)))
            .foregroundStyle(theme.ink)
            .padding(.horizontal, 9)
            .frame(height: 30)
            .background(theme.surface2)
            .clipShape(RoundedRectangle(cornerRadius: 8))
    }
}
