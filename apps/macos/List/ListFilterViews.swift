import SwiftUI

/// Filter popover for work lists: free text over title/author/summary plus
/// toggles for the distinct tags present in the current list.
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
        let tags = model.availableTags(for: section)
        VStack(alignment: .leading, spacing: 10) {
            header("Filter Works", clearEnabled: filter.wrappedValue.isActive) {
                model.workListFilters[section] = nil
            }
            filterField("Title, author, or summary", text: filter.text)
            HStack(spacing: 8) {
                filterField("Kudos (e.g. >1000)", text: filter.kudos)
                filterField("Words (e.g. <50000)", text: filter.words)
            }

            if !tags.isEmpty {
                Text("TAGS")
                    .font(Font(MacFont.ui(10, weight: .bold)))
                    .kerning(0.6)
                    .foregroundStyle(theme.ink3)
                ScrollView {
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(tags, id: \.self) { tag in
                            tagRow(tag)
                        }
                    }
                }
                .frame(maxHeight: 240)
            }
        }
        .padding(14)
        .frame(width: 320)
        .background(theme.surface)
    }

    private func tagRow(_ tag: String) -> some View {
        let on = filter.wrappedValue.tags.contains(tag)
        return Button {
            var f = filter.wrappedValue
            if on { f.tags.remove(tag) } else { f.tags.insert(tag) }
            filter.wrappedValue = f
        } label: {
            HStack(spacing: 8) {
                Image(systemName: on ? "checkmark.square.fill" : "square")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(on ? theme.accent : theme.ink3)
                Text(tag)
                    .font(Font(MacFont.ui(12)))
                    .foregroundStyle(theme.ink)
                    .lineLimit(1)
                Spacer()
            }
            .padding(.vertical, 3)
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
