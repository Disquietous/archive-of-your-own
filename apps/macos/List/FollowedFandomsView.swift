import AppKit
import SwiftUI

// MARK: - Followed fandoms

struct FollowedFandomsView: View {
    @Bindable var theme: AppTheme
    @Bindable var model: MacAppModel

    @State private var newFandom = ""
    @State private var localSuggestions: [String] = []
    @State private var remoteSuggestions: [String] = []
    @State private var isLookingUp = false
    @State private var lookupError: String?
    @FocusState private var followFocused: Bool

    /// Library work counts per fandom, shown inline on each followed row.
    private var libraryCounts: [String: Int] {
        Dictionary(uniqueKeysWithValues: model.appState.libraryFandoms.map { ($0.name, $0.count) })
    }

    private var followTerm: String {
        newFandom.trimmingCharacters(in: .whitespaces)
    }

    private var showFollowSuggestions: Bool {
        followFocused && followTerm.count >= 2
    }

    private var filteredFandoms: [String] {
        let needle = model.lists.fandomsListFilter.trimmingCharacters(in: .whitespaces).lowercased()
        guard !needle.isEmpty else { return model.follows.followedFandoms }
        return model.follows.followedFandoms.filter { $0.lowercased().contains(needle) }
    }

    var body: some View {
        let _ = theme.uiFontScale  // track app text size so fonts refresh live
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                followField
                    .padding(.init(top: 12, leading: 16, bottom: 2, trailing: 16))

                if model.follows.followedFandoms.isEmpty {
                    VStack(spacing: 8) {
                        Image(systemName: "flame")
                            .font(.system(size: 30, weight: .light))
                            .foregroundStyle(theme.line2)
                        Text("Follow your fandoms")
                            .font(Font(MacFont.serif(19, weight: .semibold)))
                            .foregroundStyle(theme.ink2)
                        Text("Followed fandoms live here — one click opens that fandom's works on the archive.")
                            .font(Font(MacFont.ui(13)))
                            .foregroundStyle(theme.ink3)
                            .multilineTextAlignment(.center)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 24)
                } else {
                    VStack(spacing: 0) {
                        ForEach(filteredFandoms, id: \.self) { name in
                            fandomRow(name)
                        }
                    }
                }
            }
        }
    }

    private var followField: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 7) {
                Image(systemName: "plus")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(theme.ink3)
                TextField("Follow a fandom…", text: $newFandom)
                    .textFieldStyle(.plain)
                    .font(Font(MacFont.ui(12.5)))
                    .foregroundStyle(theme.ink)
                    .focused($followFocused)
                    .onSubmit { follow(followTerm) }
                    .onChange(of: newFandom) { _, _ in refreshLocalSuggestions() }
            }
            .padding(.horizontal, 10)
            .frame(height: 32)
            .background(theme.surface)
            .clipShape(RoundedRectangle(cornerRadius: 9))
            .overlay(RoundedRectangle(cornerRadius: 9)
                .stroke(followFocused ? theme.accent : theme.line, lineWidth: 1))

            if showFollowSuggestions {
                followSuggestionList
            }
        }
    }

    /// Same suggestion pattern as TagTokenField: instant local matches from
    /// the known-tags cache, with an explicit "Search AO3" row as the only
    /// network trigger; results there are AO3's canonical fandom tags.
    private var followSuggestionList: some View {
        VStack(alignment: .leading, spacing: 0) {
            if !localSuggestions.isEmpty {
                followSuggestionHeader("From your library")
                ForEach(localSuggestions, id: \.self) { followSuggestionRow($0) }
            }
            if !remoteSuggestions.isEmpty {
                followSuggestionHeader("From AO3")
                ForEach(remoteSuggestions, id: \.self) { followSuggestionRow($0) }
            }
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
                    Text(isLookingUp ? "Searching AO3…" : "Search AO3 for “\(followTerm)”…")
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

    private func followSuggestionHeader(_ title: String) -> some View {
        Text(title.uppercased())
            .font(Font(MacFont.ui(9.5, weight: .bold)))
            .kerning(0.5)
            .foregroundStyle(theme.ink3)
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
    }

    private func followSuggestionRow(_ name: String) -> some View {
        Button {
            follow(name)
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

    private func refreshLocalSuggestions() {
        remoteSuggestions = []
        lookupError = nil
        guard followTerm.count >= 2 else {
            localSuggestions = []
            return
        }
        localSuggestions = model.appState.bridge
            .searchLocalTags(tagType: "fandom", term: followTerm)
            .filter { !model.follows.followedFandoms.contains($0) }
    }

    private func lookUpOnAO3() {
        let term = followTerm
        guard !term.isEmpty, !isLookingUp else { return }
        isLookingUp = true
        lookupError = nil
        Task { @MainActor in
            do {
                let names = try await model.appState.bridge.autocompleteTagsRemote(tagType: "fandom", term: term)
                if names.isEmpty {
                    lookupError = "No matching fandoms on AO3."
                } else {
                    remoteSuggestions = names.filter {
                        !model.follows.followedFandoms.contains($0) && !localSuggestions.contains($0)
                    }
                }
            } catch {
                lookupError = "Couldn’t reach the archive."
            }
            isLookingUp = false
        }
    }

    private func follow(_ name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        model.follows.followFandom(trimmed)
        newFandom = ""
        localSuggestions = []
        remoteSuggestions = []
        lookupError = nil
    }

    private func fandomRow(_ name: String) -> some View {
        // Same selection treatment as the work and author lists: accent-soft
        // fill with a 3pt accent bar on the leading edge.
        let selected = model.fandomWorksTag == name
        let count = libraryCounts[name] ?? 0
        return Button {
            model.openFandomWorks(name)
        } label: {
            HStack(spacing: 12) {
                RoundedRectangle(cornerRadius: 10)
                    .fill(Fandom.spineColor(for: name))
                    .frame(width: 34, height: 34)
                    .overlay {
                        Image(systemName: "flame")
                            .font(.system(size: 14, weight: .medium))
                            .foregroundStyle(theme.onAccent)
                    }
                VStack(alignment: .leading, spacing: 1) {
                    Text(name)
                        .font(Font(MacFont.ui(14.5, weight: .semibold)))
                        .foregroundStyle(theme.ink)
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)
                    Text(count == 1 ? "1 work in library" : "\(count) works in library")
                        .font(Font(MacFont.ui(12)))
                        .foregroundStyle(theme.ink3)
                }
                Spacer()
                Button {
                    model.follows.unfollowFandom(name)
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(theme.ink3)
                        .frame(width: 22, height: 22)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Unfollow")
                Image(systemName: "chevron.right")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(theme.ink3)
            }
            .padding(.init(top: 13, leading: 16, bottom: 13, trailing: 16))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background(selected ? theme.accentSoft : .clear)
        .overlay(alignment: .leading) {
            if selected { theme.accent.frame(width: 3) }
        }
        .overlay(alignment: .bottom) { theme.line.frame(height: 1) }
    }
}
