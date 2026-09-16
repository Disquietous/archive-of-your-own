import SwiftUI

/// Token field for AO3 canonical-tag inputs (fandoms, characters,
/// relationships, additional tags, creators). Committed tags render as
/// removable chips; typing suggests from the local tags cache instantly
/// (never the network); a visible "Search AO3" row is the ONLY action that
/// fires a request — its results are cached as canonical.
struct TagTokenField: View {
    @Environment(AppTheme.self) private var theme
    @Environment(AppState.self) private var state

    let label: String
    /// One of AO3's tag types (fandom, character, relationship, freeform,
    /// creator), or "" for any-type fields: local suggestions come from
    /// every cached tag, and the AO3 lookup uses the generic endpoint.
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
        VStack(alignment: .leading, spacing: 6) {
            Text(label.uppercased())
                .font(.custom("HankenGrotesk", size: 10.5).weight(.bold))
                .tracking(0.6)
                .foregroundStyle(theme.ink3)

            VStack(alignment: .leading, spacing: 8) {
                if !tokens.isEmpty {
                    FlowLayout(spacing: 6) {
                        ForEach(tokens, id: \.self) { token in
                            chip(token)
                        }
                    }
                }
                TextField("Add \(label.lowercased())…", text: $input)
                    .textFieldStyle(.plain)
                    .font(.custom("HankenGrotesk", size: 14))
                    .foregroundStyle(theme.ink)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                    .focused($focused)
                    .submitLabel(.done)
                    .onSubmit { commit(term) }
                    .onChange(of: input) { _, _ in refreshLocalSuggestions() }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(theme.surface2)
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10)
                .stroke(focused ? theme.accent : theme.line, lineWidth: 1))

            if showSuggestions {
                suggestionList
            }
        }
    }

    private func chip(_ token: String) -> some View {
        HStack(spacing: 5) {
            Text(token)
                .font(.custom("HankenGrotesk", size: 12.5).weight(.medium))
                .foregroundStyle(theme.ink2)
                .lineLimit(1)
            Button {
                remove(token)
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
        .background(theme.surface)
        .clipShape(Capsule())
        .overlay(Capsule().stroke(theme.line, lineWidth: 1))
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
                            .font(.system(size: 13, weight: .medium))
                    }
                    Text(isLookingUp ? "Searching AO3…" : "Search AO3 for “\(term)”…")
                        .font(.custom("HankenGrotesk", size: 13).weight(.semibold))
                    Spacer()
                }
                .foregroundStyle(theme.accent)
                .padding(.horizontal, 12)
                .padding(.vertical, 9)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(isLookingUp)
            if let lookupError {
                Text(lookupError)
                    .font(.custom("HankenGrotesk", size: 12))
                    .foregroundStyle(Color(hex: "CE514D"))
                    .padding(.horizontal, 12)
                    .padding(.bottom, 8)
            }
        }
        .padding(.vertical, 4)
        .background(theme.surface)
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(theme.line, lineWidth: 1))
    }

    private func suggestionHeader(_ title: String) -> some View {
        Text(title.uppercased())
            .font(.custom("HankenGrotesk", size: 10).weight(.bold))
            .tracking(0.5)
            .foregroundStyle(theme.ink3)
            .padding(.horizontal, 12)
            .padding(.vertical, 5)
    }

    private func suggestionRow(_ name: String) -> some View {
        Button {
            commit(name)
        } label: {
            Text(name)
                .font(.custom("HankenGrotesk", size: 14))
                .foregroundStyle(theme.ink)
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
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
        let names = tagType.isEmpty
            ? state.bridge.searchLibraryTags(term, limit: 12).map(\.name)
            : state.bridge.searchLocalTags(tagType: tagType, term: term)
        localSuggestions = names.filter { !tokens.contains($0) }
    }

    private func lookUpOnAO3() {
        let lookupTerm = term
        guard !lookupTerm.isEmpty, !isLookingUp else { return }
        isLookingUp = true
        lookupError = nil
        Task { @MainActor in
            do {
                let names = try await state.bridge.autocompleteTagsRemote(
                    tagType: tagType.isEmpty ? "tag" : tagType, term: lookupTerm)
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
