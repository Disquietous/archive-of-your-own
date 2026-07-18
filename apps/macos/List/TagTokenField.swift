import SwiftUI

/// Token field for AO3 canonical-tag search inputs (fandoms, characters,
/// relationships, additional tags, creators). Committed tags render as
/// removable chips; typing suggests from the local known-tags cache
/// instantly (never the network); a visible "Search AO3" row is the ONLY
/// action that fires a request — its results are cached as canonical.
struct TagTokenField: View {
    @Bindable var theme: AppTheme
    @Bindable var appState: AppState
    let label: String
    let tagType: String
    /// The comma-separated form value AO3 expects.
    @Binding var value: String

    @State private var input = ""
    @State private var localSuggestions: [String] = []
    @State private var remoteSuggestions: [String] = []
    @State private var isLookingUp = false
    @State private var lookupError: String?
    @FocusState private var focused: Bool

    private var tokens: [String] {
        value.split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    private var term: String {
        input.trimmingCharacters(in: .whitespaces)
    }

    private var showSuggestions: Bool {
        focused && term.count >= 2
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(label.uppercased())
                .font(Font(MacFont.ui(10.5, weight: .bold)))
                .kerning(0.6)
                .foregroundStyle(theme.ink3)

            VStack(alignment: .leading, spacing: 6) {
                if !tokens.isEmpty {
                    FlowLayout(spacing: 5) {
                        ForEach(tokens, id: \.self) { token in
                            chip(token)
                        }
                    }
                }
                TextField("Add \(label.lowercased())…", text: $input)
                    .textFieldStyle(.plain)
                    .font(Font(MacFont.ui(12.5)))
                    .foregroundStyle(theme.ink)
                    .focused($focused)
                    .onSubmit { commit(term) }
                    .onChange(of: input) { _, _ in refreshLocalSuggestions() }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(theme.surface)
            .clipShape(RoundedRectangle(cornerRadius: 9))
            .overlay(RoundedRectangle(cornerRadius: 9)
                .stroke(focused ? theme.accent : theme.line, lineWidth: 1))

            if showSuggestions {
                suggestionList
            }
        }
    }

    private func chip(_ token: String) -> some View {
        HStack(spacing: 4) {
            Text(token)
                .font(Font(MacFont.ui(11.5, weight: .medium)))
                .foregroundStyle(theme.ink2)
                .lineLimit(1)
            Button {
                remove(token)
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

    private var suggestionList: some View {
        VStack(alignment: .leading, spacing: 0) {
            if !localSuggestions.isEmpty {
                suggestionHeader("From your library")
                ForEach(localSuggestions, id: \.self) { suggestionRow($0) }
            }
            if !remoteSuggestions.isEmpty {
                suggestionHeader("From AO3")
                ForEach(remoteSuggestions, id: \.self) { suggestionRow($0) }
            }
            // The explicit — and only — network trigger.
            Button {
                lookUpOnAO3()
            } label: {
                HStack(spacing: 6) {
                    if isLookingUp {
                        ProgressView().controlSize(.mini)
                    } else {
                        Image(systemName: "magnifyingglass.circle")
                            .font(.system(size: 11, weight: .medium))
                    }
                    Text(isLookingUp ? "Searching AO3…" : "Search AO3 for “\(term)”…")
                        .font(Font(MacFont.ui(11.5, weight: .semibold)))
                    Spacer()
                }
                .foregroundStyle(theme.accent)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(isLookingUp)
            if let lookupError {
                Text(lookupError)
                    .font(Font(MacFont.ui(11)))
                    .foregroundStyle(Color(hex: "CE514D"))
                    .padding(.horizontal, 10)
                    .padding(.bottom, 6)
            }
        }
        .padding(.vertical, 4)
        .background(theme.surface)
        .clipShape(RoundedRectangle(cornerRadius: 9))
        .overlay(RoundedRectangle(cornerRadius: 9).stroke(theme.line, lineWidth: 1))
    }

    private func suggestionHeader(_ title: String) -> some View {
        Text(title.uppercased())
            .font(Font(MacFont.ui(9.5, weight: .bold)))
            .kerning(0.5)
            .foregroundStyle(theme.ink3)
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
    }

    private func suggestionRow(_ name: String) -> some View {
        Button {
            commit(name)
        } label: {
            Text(name)
                .font(Font(MacFont.ui(12)))
                .foregroundStyle(theme.ink)
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: - Behavior

    private func refreshLocalSuggestions() {
        remoteSuggestions = []
        lookupError = nil
        guard term.count >= 2 else {
            localSuggestions = []
            return
        }
        localSuggestions = appState.bridge
            .searchLocalTags(tagType: tagType, term: term)
            .filter { !tokens.contains($0) }
    }

    private func lookUpOnAO3() {
        let lookupTerm = term
        guard !lookupTerm.isEmpty, !isLookingUp else { return }
        isLookingUp = true
        lookupError = nil
        Task { @MainActor in
            do {
                let names = try await appState.bridge.autocompleteTagsRemote(tagType: tagType, term: lookupTerm)
                if names.isEmpty {
                    lookupError = "No matching tags on AO3."
                } else {
                    remoteSuggestions = names.filter { !tokens.contains($0) && !localSuggestions.contains($0) }
                }
            } catch {
                lookupError = "Couldn’t reach the archive."
            }
            isLookingUp = false
        }
    }

    private func commit(_ token: String) {
        let trimmed = token.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        var current = tokens
        if !current.contains(trimmed) {
            current.append(trimmed)
            value = current.joined(separator: ", ")
        }
        input = ""
        localSuggestions = []
        remoteSuggestions = []
        lookupError = nil
    }

    private func remove(_ token: String) {
        value = tokens.filter { $0 != token }.joined(separator: ", ")
    }
}
