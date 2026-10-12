import SwiftUI

/// Type-to-look-up field over the user's saved searches: typing filters
/// the saved list by name — no network, the list is already loaded from
/// the database. Picking one prefills the whole criteria form (ready to
/// tweak and run); clearing the text only clears the field, never the
/// form. Each suggestion row carries a × to delete that saved search. The
/// Save button persists the current criteria under the typed name
/// (Update when the name already exists).
struct SavedSearchField: View {
    @Environment(AppTheme.self) private var theme
    @Environment(AppState.self) private var state
    @Environment(SearchModel.self) private var search

    @State private var input = ""
    @FocusState private var focused: Bool

    private var term: String {
        input.trimmingCharacters(in: .whitespaces)
    }

    /// Names are unique in the database (case-insensitively) — saving to an
    /// existing name overwrites that search, so the button reads Update.
    private var nameExists: Bool {
        search.savedSearches.contains { $0.name.caseInsensitiveCompare(term) == .orderedSame }
    }

    /// Saved searches are a short, already-loaded list — focusing shows
    /// them all, typing narrows by name.
    private var matches: [USavedSearch] {
        guard !term.isEmpty else { return search.savedSearches }
        return search.savedSearches.filter { $0.name.localizedCaseInsensitiveContains(term) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("SAVED SEARCH")
                .font(.custom("HankenGrotesk", size: 10.5).weight(.bold))
                .tracking(0.6)
                .foregroundStyle(theme.ink3)
            HStack(spacing: 8) {
                Image(systemName: "star")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(theme.ink3)
                TextField("Type to find a saved search…", text: $input)
                    .textFieldStyle(.plain)
                    .font(.custom("HankenGrotesk", size: 15).weight(.medium))
                    .foregroundStyle(theme.ink)
                    .autocorrectionDisabled()
                    .focused($focused)
                    .submitLabel(.done)
                    .onSubmit { save() }
                Button(nameExists ? "Update" : "Save") { save() }
                    .font(Typography.smallButtonLabel())
                    .foregroundStyle(term.isEmpty ? theme.ink3 : theme.accent)
                    .disabled(term.isEmpty)
                    .fixedSize()
            }
            .padding(.horizontal, 12)
            .frame(height: 42)
            .background(theme.surface2)
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10)
                .stroke(focused ? theme.accent : theme.line, lineWidth: 1))

            if focused && !matches.isEmpty {
                suggestionList
            }
        }
    }

    private func save() {
        guard !term.isEmpty else { return }
        search.saveCurrentSearch(named: term, appState: state)
        focused = false
    }

    private var suggestionList: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(matches, id: \.id) { saved in
                HStack(spacing: 6) {
                    Button {
                        search.applySavedSearch(saved)
                        input = saved.name
                        focused = false
                    } label: {
                        VStack(alignment: .leading, spacing: 1) {
                            Text(saved.name)
                                .font(Typography.uiBody())
                                .foregroundStyle(theme.ink)
                                .lineLimit(1)
                            if let summary = SearchModel.summary(of: saved) {
                                Text(summary)
                                    .font(Typography.uiSmall())
                                    .foregroundStyle(theme.ink3)
                                    .lineLimit(1)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    Button {
                        search.deleteSavedSearch(saved.id, appState: state)
                    } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 11, weight: .bold))
                            .foregroundStyle(theme.ink3)
                            .frame(width: 28, height: 28)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Delete saved search \(saved.name)")
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
            }
        }
        .padding(.vertical, 4)
        .background(theme.surface)
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(theme.line, lineWidth: 1))
    }
}
