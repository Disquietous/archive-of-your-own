import SwiftUI

/// Filter sheet for a work list: free text over title/author/summary,
/// kudos/words expressions, and fandom/tag chips fed by type-ahead over the
/// values present in the current list. Mirrors the macOS
/// `WorkListFilterView`; the filter itself lives in `LibraryListModel`.
struct WorkListFilterSheet: View {
    @Environment(AppTheme.self) private var theme
    @Environment(LibraryListModel.self) private var lists
    @Environment(\.dismiss) private var dismiss

    let section: LibrarySection
    let availableTags: [String]
    let availableFandoms: [String]

    private var filter: Binding<LibraryListModel.WorkListFilter> {
        Binding(get: { lists.workListFilter(for: section) },
                set: { lists.workListFilters[section] = $0 })
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    FilterTextField(placeholder: "Title, author, or summary", text: filter.text)
                    HStack(spacing: 8) {
                        FilterTextField(placeholder: "Kudos (e.g. >1000)", text: filter.kudos)
                            .keyboardType(.numbersAndPunctuation)
                        FilterTextField(placeholder: "Words (e.g. <50000)", text: filter.words)
                            .keyboardType(.numbersAndPunctuation)
                    }
                    TokenFilterSection(label: "Fandom", placeholder: "Type to add a fandom…",
                                       selected: filter.fandoms, allOptions: availableFandoms)
                    TokenFilterSection(label: "Tags", placeholder: "Type to add a tag…",
                                       selected: filter.tags, allOptions: availableTags)
                    FilterRetentionToggle()
                }
                .padding(theme.pad)
            }
            .background(theme.bg)
            .scrollDismissesKeyboard(.interactively)
            .navigationTitle("Filter Works")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Clear") { lists.workListFilters[section] = nil }
                        .disabled(!filter.wrappedValue.isActive)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
    }
}

/// The app-wide filter-retention switch, offered in every filter sheet so
/// the choice is at hand wherever a filter is set.
struct FilterRetentionToggle: View {
    @Environment(AppTheme.self) private var theme
    @Environment(LibraryListModel.self) private var lists

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Toggle("Keep filter across lists", isOn: Binding(
                get: { lists.retainListFilters },
                set: { lists.setRetainListFilters($0) }))
                .font(.custom("HankenGrotesk", size: 14).weight(.medium))
                .foregroundStyle(theme.ink)
                .tint(theme.accent)
            Text(lists.retainListFilters
                 ? "Filters stay put as you move between authors, fandoms, and searches."
                 : "A filter clears itself when the list it was set on closes or changes.")
                .font(.custom("HankenGrotesk", size: 12))
                .foregroundStyle(theme.ink3)
        }
        .padding(.top, 4)
    }
}

/// Chips + type-ahead selector over a fixed option pool (the values present
/// in the current list) — the filter sheet's fandom and tag sections.
struct TokenFilterSection: View {
    @Environment(AppTheme.self) private var theme

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
    }

    /// Rows shown before the suggestion list scrolls.
    private static let visibleSuggestionRows = 8

    /// Fixed row height (tracks Dynamic Type) so the list can size to its
    /// matches up to the visible cap, then scroll through the rest.
    @ScaledMetric(relativeTo: .body) private var suggestionRowHeight: CGFloat = 38

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(label.uppercased())
                .font(.custom("HankenGrotesk", size: 10.5).weight(.bold))
                .tracking(0.6)
                .foregroundStyle(theme.ink3)
            if !selected.isEmpty {
                FlowLayout(spacing: 6) {
                    ForEach(selected.sorted(), id: \.self) { value in
                        chip(value)
                    }
                }
            }
            FilterTextField(placeholder: placeholder, text: $input)
                .onSubmit {
                    if let first = suggestions.first { add(first) }
                }
            if !suggestions.isEmpty {
                let matches = suggestions
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(matches, id: \.self) { value in
                            Button {
                                add(value)
                            } label: {
                                Text(value)
                                    .font(.custom("HankenGrotesk", size: 14))
                                    .foregroundStyle(theme.ink)
                                    .lineLimit(1)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .padding(.horizontal, 12)
                                    .frame(height: suggestionRowHeight)
                                    .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .overlay(alignment: .bottom) {
                                if value != matches.last {
                                    Divider().padding(.leading, 12)
                                }
                            }
                        }
                    }
                }
                .frame(height: suggestionRowHeight
                       * CGFloat(min(matches.count, Self.visibleSuggestionRows)))
                .background(theme.surface)
                .clipShape(RoundedRectangle(cornerRadius: 10))
                .overlay(RoundedRectangle(cornerRadius: 10).stroke(theme.line, lineWidth: 1))
            }
        }
    }

    private func add(_ value: String) {
        selected.insert(value)
        input = ""
    }

    private func chip(_ value: String) -> some View {
        HStack(spacing: 5) {
            Text(value)
                .font(.custom("HankenGrotesk", size: 12.5).weight(.medium))
                .foregroundStyle(theme.ink2)
                .lineLimit(1)
            Button {
                selected.remove(value)
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(theme.ink3)
                    .frame(width: 18, height: 18)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .padding(.leading, 10)
        .padding(.trailing, 4)
        .padding(.vertical, 4)
        .background(theme.surface2)
        .clipShape(Capsule())
    }
}

struct FilterTextField: View {
    @Environment(AppTheme.self) private var theme

    let placeholder: String
    @Binding var text: String

    var body: some View {
        TextField(placeholder, text: $text)
            .textFieldStyle(.plain)
            .font(.custom("HankenGrotesk", size: 14))
            .foregroundStyle(theme.ink)
            .autocorrectionDisabled()
            .textInputAutocapitalization(.never)
            .padding(.horizontal, 12)
            .frame(height: 40)
            .background(theme.surface)
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(theme.line, lineWidth: 1))
    }
}
