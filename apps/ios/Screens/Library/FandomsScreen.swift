import SwiftUI

/// Followed fandoms: a follow field with local + explicit AO3 suggestions,
/// one row per followed fandom (library work count), tap → the library's
/// works in that fandom with a "Search AO3" hand-off.
struct FandomsScreen: View {
    @Environment(AppTheme.self) private var theme
    @Environment(AppState.self) private var state
    @Environment(NavigationState.self) private var nav
    @Environment(FollowModel.self) private var follows
    @Environment(LibraryListModel.self) private var lists

    @State private var newFandom = ""
    @State private var localSuggestions: [String] = []
    @State private var remoteSuggestions: [String] = []
    @State private var isLookingUp = false
    @State private var lookupError: String?
    @FocusState private var followFocused: Bool

    private var libraryCounts: [String: Int] {
        Dictionary(uniqueKeysWithValues: state.libraryFandoms.map { ($0.name, $0.count) })
    }

    private var followTerm: String {
        newFandom.trimmingCharacters(in: .whitespaces)
    }

    private var showFollowSuggestions: Bool {
        followFocused && followTerm.count >= 2
    }

    private var filteredFandoms: [String] {
        let needle = lists.fandomsListFilter.trimmingCharacters(in: .whitespaces).lowercased()
        guard !needle.isEmpty else { return follows.followedFandoms }
        return follows.followedFandoms.filter { $0.lowercased().contains(needle) }
    }

    var body: some View {
        @Bindable var lists = lists
        ZStack(alignment: .top) {
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    followField
                    if follows.followedFandoms.count > 6 {
                        ListFilterField(text: $lists.fandomsListFilter, placeholder: "Filter fandoms")
                    }

                    if follows.followedFandoms.isEmpty {
                        EmptyStateView(systemImage: "flame", title: "Follow your fandoms",
                                       subtitle: "Followed fandoms live here — one tap opens that fandom’s works.")
                            .padding(.top, 32)
                    } else {
                        VStack(spacing: 0) {
                            ForEach(filteredFandoms, id: \.self) { name in
                                fandomRow(name)
                                if name != filteredFandoms.last {
                                    Divider().padding(.leading, 62)
                                }
                            }
                        }
                        .background(theme.surface)
                        .clipShape(RoundedRectangle(cornerRadius: Radius.card))
                        .overlay(RoundedRectangle(cornerRadius: Radius.card).stroke(theme.line, lineWidth: 1))
                    }
                }
                .padding(.horizontal, theme.pad)
                .padding(.bottom, 32)
            }
            .contentMargins(.top, ScreenChromeMetrics.height, for: .scrollContent)
            .scrollDismissesKeyboard(.interactively)

            let followedCount = follows.followedFandoms.count
            ScreenChrome(title: "Fandoms",
                         subtitle: followedCount == 1 ? "1 followed" : "\(followedCount) followed")
        }
        .libraryScreen()
    }

    // MARK: - Follow field

    private var followField: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Image(systemName: "plus")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(theme.ink3)
                TextField("Follow a fandom…", text: $newFandom)
                    .textFieldStyle(.plain)
                    .font(.custom("HankenGrotesk", size: 14))
                    .foregroundStyle(theme.ink)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                    .focused($followFocused)
                    .submitLabel(.done)
                    .onSubmit { follow(followTerm) }
                    .onChange(of: newFandom) { _, _ in refreshLocalSuggestions() }
            }
            .padding(.horizontal, 12)
            .frame(height: 42)
            .background(theme.surface)
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10)
                .stroke(followFocused ? theme.accent : theme.line, lineWidth: 1))

            if showFollowSuggestions {
                followSuggestionList
            }
        }
    }

    /// Instant local matches from the known-tags cache, with an explicit
    /// "Search AO3" row as the only network trigger.
    private var followSuggestionList: some View {
        VStack(alignment: .leading, spacing: 0) {
            if !localSuggestions.isEmpty {
                suggestionHeader("From your library")
                ForEach(localSuggestions, id: \.self) { suggestionRow($0) }
            }
            if !remoteSuggestions.isEmpty {
                suggestionHeader("From AO3")
                ForEach(remoteSuggestions, id: \.self) { suggestionRow($0) }
            }
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
                    Text(isLookingUp ? "Searching AO3…" : "Search AO3 for “\(followTerm)”…")
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
            follow(name)
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

    private func refreshLocalSuggestions() {
        remoteSuggestions = []
        lookupError = nil
        guard followTerm.count >= 2 else {
            localSuggestions = []
            return
        }
        localSuggestions = state.bridge
            .searchLocalTags(tagType: "fandom", term: followTerm)
            .filter { !follows.followedFandoms.contains($0) }
    }

    private func lookUpOnAO3() {
        let term = followTerm
        guard !term.isEmpty, !isLookingUp else { return }
        isLookingUp = true
        lookupError = nil
        Task { @MainActor in
            do {
                let names = try await state.bridge.autocompleteTagsRemote(tagType: "fandom", term: term)
                if names.isEmpty {
                    lookupError = "No matching fandoms on AO3."
                } else {
                    remoteSuggestions = names.filter {
                        !follows.followedFandoms.contains($0) && !localSuggestions.contains($0)
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
        follows.followFandom(trimmed)
        newFandom = ""
        localSuggestions = []
        remoteSuggestions = []
        lookupError = nil
        followFocused = false
    }

    // MARK: - Rows

    private func fandomRow(_ name: String) -> some View {
        let count = libraryCounts[name] ?? 0
        return Button {
            nav.openFandomWorks(name)
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
                VStack(alignment: .leading, spacing: 2) {
                    Text(name)
                        .font(.custom("HankenGrotesk", size: 15).weight(.semibold))
                        .foregroundStyle(theme.ink)
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)
                    Text(count == 1 ? "1 work in library" : "\(count) works in library")
                        .font(.custom("HankenGrotesk", size: 12))
                        .foregroundStyle(theme.ink3)
                }
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(theme.ink3)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button {
                nav.openAO3TagListing(name)
            } label: {
                Label("Search AO3", systemImage: "magnifyingglass")
            }
            Button(role: .destructive) {
                follows.unfollowFandom(name)
            } label: {
                Label("Unfollow", systemImage: "xmark")
            }
        }
    }
}

/// A single-field filter box used by the Fandoms/Authors screens.
struct ListFilterField: View {
    @Environment(AppTheme.self) private var theme

    @Binding var text: String
    let placeholder: String

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(theme.ink3)
            TextField(placeholder, text: $text)
                .textFieldStyle(.plain)
                .font(.custom("HankenGrotesk", size: 14))
                .foregroundStyle(theme.ink)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
            if !text.isEmpty {
                Button {
                    text = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 14))
                        .foregroundStyle(theme.ink3)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 12)
        .frame(height: 40)
        .background(theme.surface)
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(theme.line, lineWidth: 1))
    }
}

/// Fandoms drill-in: the library's works tagged with one fandom (session
/// list filter only, natural order), with the "Search AO3" hand-off.
struct FandomWorksScreen: View {
    @Environment(AppTheme.self) private var theme
    @Environment(AppState.self) private var state
    @Environment(NavigationState.self) private var nav
    @Environment(LibraryListModel.self) private var lists

    let tag: String

    /// The filter is scoped to this drill-in: clear it once when a new
    /// fandom opens (not on every re-appear after a pushed detail pops).
    @State private var didOpen = false

    var body: some View {
        WorkListScreen(
            section: .fandoms,
            title: tag,
            rawWorks: { state.libraryWorks(inFandom: tag) },
            empty: .init(systemImage: "flame", title: "Nothing in your library yet",
                         subtitle: "Works you open from this fandom are kept here. Search AO3 to find some."),
            usesSectionPrefs: false,
            header: AnyView(searchHandoff),
            menuItems: AnyView(
                Button {
                    nav.openAO3TagListing(tag)
                } label: {
                    Label("Search AO3", systemImage: "magnifyingglass")
                }
            )
        )
        .onAppear {
            guard !didOpen else { return }
            didOpen = true
            lists.listEmptied(.fandoms)
        }
    }

    private var searchHandoff: some View {
        Button {
            nav.openAO3TagListing(tag)
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 13, weight: .semibold))
                Text("Search AO3 for this fandom")
                    .font(Typography.smallButtonLabel())
                Spacer()
                Image(systemName: "arrow.up.right")
                    .font(.system(size: 11, weight: .semibold))
            }
            .foregroundStyle(theme.accent)
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(
                RoundedRectangle(cornerRadius: Radius.smallButton)
                    .stroke(theme.accent, lineWidth: 1)
            )
        }
        .buttonStyle(ButtonPressStyle())
    }
}
