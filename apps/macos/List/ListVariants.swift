import AppKit
import SwiftUI

// SwiftUI content for the list pane's non-table variants, hosted from the
// AppKit ListPaneViewController. All data comes from the shared AppState.

// MARK: - Tag chips (browse/search)

/// Simple leading-aligned wrapping layout (no horizontal scrolling).
struct FlowLayout: Layout {
    var spacing: CGFloat = 7

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        arrange(subviews, in: proposal.width ?? 384).size
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let frames = arrange(subviews, in: bounds.width).frames
        for (frame, subview) in zip(frames, subviews) {
            subview.place(at: CGPoint(x: bounds.minX + frame.minX, y: bounds.minY + frame.minY),
                          proposal: ProposedViewSize(frame.size))
        }
    }

    private func arrange(_ subviews: Subviews, in width: CGFloat) -> (frames: [CGRect], size: CGSize) {
        var frames: [CGRect] = []
        var x: CGFloat = 0, y: CGFloat = 0, rowHeight: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > 0, x + size.width > width {
                x = 0
                y += rowHeight + spacing
                rowHeight = 0
            }
            frames.append(CGRect(origin: CGPoint(x: x, y: y), size: size))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
        return (frames, CGSize(width: width, height: y + rowHeight))
    }
}

// MARK: - Empty / loading / error states

struct EmptyStateMac: View {
    @Bindable var theme: AppTheme
    let icon: String, title: String, message: String

    var body: some View {
        let _ = theme.uiFontScale  // track app text size so fonts refresh live
        VStack(spacing: 0) {
            Image(systemName: icon)
                .font(.system(size: 34, weight: .light))
                .foregroundStyle(theme.line2)
                .padding(.bottom, 16)
            Text(title)
                .font(Font(MacFont.serif(21, weight: .semibold)))
                .foregroundStyle(theme.ink2)
                .padding(.bottom, 8)
            Text(message)
                .font(Font(MacFont.ui(14)))
                .foregroundStyle(theme.ink3)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 320)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(40)
    }
}

struct LoadingStateMac: View {
    @Bindable var theme: AppTheme
    let message: String
    var detail: String? = nil
    /// Other requests in flight, shown as a summary beneath the primary
    /// message so the user sees everything underway, not just this one.
    var otherActivity: [String] = []
    var onCancel: (() -> Void)? = nil

    var body: some View {
        let _ = theme.uiFontScale  // track app text size so fonts refresh live
        VStack(spacing: 14) {
            ProgressView()
                .controlSize(.regular)
            Text(message)
                .font(Font(MacFont.ui(13.5, weight: .semibold)))
                .foregroundStyle(theme.ink2)
            if let detail {
                Text(detail)
                    .font(Font(MacFont.ui(12)))
                    .foregroundStyle(theme.ink3)
                    .multilineTextAlignment(.center)
            }
            if !otherActivity.isEmpty {
                VStack(spacing: 5) {
                    Text("ALSO IN PROGRESS")
                        .font(Font(MacFont.ui(9.5, weight: .bold)))
                        .kerning(0.6)
                        .foregroundStyle(theme.ink3)
                    ForEach(otherActivity, id: \.self) { op in
                        HStack(spacing: 6) {
                            ProgressView().controlSize(.mini)
                            Text(op)
                                .font(Font(MacFont.ui(11.5)))
                                .foregroundStyle(theme.ink3)
                        }
                    }
                }
                .padding(.top, 4)
                .padding(10)
                .background(theme.surface2)
                .clipShape(RoundedRectangle(cornerRadius: 10))
            }
            if let onCancel {
                Button("Cancel", action: onCancel)
                    .buttonStyle(.plain)
                    .font(Font(MacFont.ui(12.5, weight: .semibold)))
                    .foregroundStyle(theme.ink3)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(40)
    }
}

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
        Dictionary(uniqueKeysWithValues: model.libraryFandoms.map { ($0.name, $0.count) })
    }

    private var followTerm: String {
        newFandom.trimmingCharacters(in: .whitespaces)
    }

    private var showFollowSuggestions: Bool {
        followFocused && followTerm.count >= 2
    }

    private var filteredFandoms: [String] {
        let needle = model.fandomsListFilter.trimmingCharacters(in: .whitespaces).lowercased()
        guard !needle.isEmpty else { return model.followedFandoms }
        return model.followedFandoms.filter { $0.lowercased().contains(needle) }
    }

    var body: some View {
        let _ = theme.uiFontScale  // track app text size so fonts refresh live
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                followField
                    .padding(.init(top: 12, leading: 16, bottom: 2, trailing: 16))

                if model.followedFandoms.isEmpty {
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
            .filter { !model.followedFandoms.contains($0) }
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
                        !model.followedFandoms.contains($0) && !localSuggestions.contains($0)
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
        model.followFandom(trimmed)
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
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                    Text(count == 1 ? "1 work in library" : "\(count) works in library")
                        .font(Font(MacFont.ui(12)))
                        .foregroundStyle(theme.ink3)
                }
                Spacer()
                Button {
                    model.unfollowFandom(name)
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

// MARK: - Authors (followed locally + AO3 subscriptions)

struct AuthorsList: View {
    @Bindable var theme: AppTheme
    @Bindable var appState: AppState
    @Bindable var model: MacAppModel

    @State private var newAuthor = ""

    /// Local follows first, then AO3 subscription authors not already followed.
    /// `username` is the canonical AO3 username (subscription display names
    /// can differ) — used for opening works and fetching avatars.
    private var authors: [(name: String, username: String, source: String)] {
        var seen = Set<String>()
        var result: [(String, String, String)] = []
        for name in model.followedAuthorNames where seen.insert(name).inserted {
            result.append((name, name, "Followed"))
        }
        for sub in model.followedAuthors where seen.insert(sub.name).inserted {
            result.append((sub.name, sub.id, "Subscribed on AO3"))
        }
        let needle = model.authorsListFilter.trimmingCharacters(in: .whitespaces).lowercased()
        guard !needle.isEmpty else { return result }
        return result.filter { $0.0.lowercased().contains(needle) || $0.1.lowercased().contains(needle) }
    }

    var body: some View {
        let _ = theme.uiFontScale  // track app text size so fonts refresh live
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                followField
                    .padding(.init(top: 12, leading: 16, bottom: 2, trailing: 16))

                if authors.isEmpty {
                    EmptyStateMac(theme: theme, icon: "person",
                                  title: "No authors yet",
                                  message: "Follow an author by username, or sign in to see your AO3 author subscriptions.")
                        .frame(minHeight: 260)
                } else {
                    VStack(spacing: 0) {
                        ForEach(authors, id: \.name) { author in
                            authorRow(author.name, username: author.username, source: author.source)
                        }
                    }
                }
            }
        }
    }

    private var followField: some View {
        HStack(spacing: 7) {
            Image(systemName: "plus")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(theme.ink3)
            TextField("Follow an author (AO3 username)", text: $newAuthor)
                .textFieldStyle(.plain)
                .font(Font(MacFont.ui(12.5)))
                .foregroundStyle(theme.ink)
                .onSubmit {
                    model.followAuthor(newAuthor)
                    newAuthor = ""
                }
        }
        .padding(.horizontal, 10)
        .frame(height: 32)
        .background(theme.surface)
        .clipShape(RoundedRectangle(cornerRadius: 9))
        .overlay(RoundedRectangle(cornerRadius: 9).stroke(theme.line, lineWidth: 1))
    }

    /// DB-cached AO3 avatar; the letter disc shows until (or unless) the
    /// one-time fetch delivers.
    private func authorAvatar(name: String, username: String) -> some View {
        Group {
            if let data = appState.authorAvatars[username], let image = NSImage(data: data) {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            } else {
                Circle()
                    .fill(Fandom.spineColorForHue(abs(name.hashValue % 360)))
                    .overlay {
                        Text(String(name.prefix(1)).uppercased())
                            .font(Font(MacFont.serif(18, weight: .semibold)))
                            .foregroundStyle(theme.onAccent)
                    }
            }
        }
        .frame(width: 40, height: 40)
        .clipShape(Circle())
        .onAppear { appState.loadAuthorAvatar(username) }
    }

    private func authorRow(_ name: String, username: String, source: String) -> some View {
        // Same selection treatment as the work lists: accent-soft fill
        // with a 3pt accent bar on the leading edge.
        let selected = model.authorUsername == username
        return Button {
            model.openAuthor(username)
        } label: {
            HStack(spacing: 12) {
                authorAvatar(name: name, username: username)
                VStack(alignment: .leading, spacing: 1) {
                    Text(name)
                        .font(Font(MacFont.ui(14.5, weight: .semibold)))
                        .foregroundStyle(theme.ink)
                    Text(source)
                        .font(Font(MacFont.ui(12)))
                        .foregroundStyle(theme.ink3)
                }
                Spacer()
                if model.followedAuthorNames.contains(name) {
                    Button {
                        model.unfollowAuthor(name)
                    } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundStyle(theme.ink3)
                            .frame(width: 22, height: 22)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help("Unfollow")
                }
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

// MARK: - Stats (computed on device)

struct StatsView: View {
    @Bindable var theme: AppTheme
    @Bindable var model: MacAppModel

    var body: some View {
        let _ = theme.uiFontScale  // track app text size so fonts refresh live
        let stats = model.localStats
        ScrollView {
            VStack(spacing: 14) {
                LazyVGrid(columns: [GridItem(.flexible(), spacing: 11), GridItem(.flexible())], spacing: 11) {
                    statCard(Fmt.k(stats.wordsRead), "Words read")
                    statCard("\(stats.worksFinished)", "Works finished")
                    statCard("\(stats.inLibrary)", "In library")
                    statCard("\(stats.downloaded)", "Downloaded")
                }
                Text("Counted on this device from your reading progress. Nothing leaves your library.")
                    .font(Font(MacFont.ui(12)))
                    .foregroundStyle(theme.ink3)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(20)
        }
    }

    private func statCard(_ value: String, _ label: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(value)
                .font(Font(MacFont.serif(28, weight: .semibold)))
                .foregroundStyle(theme.accent)
            Text(label)
                .font(Font(MacFont.ui(12, weight: .semibold)))
                .foregroundStyle(theme.ink3)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(theme.surface)
        .clipShape(RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(theme.line, lineWidth: 1))
    }
}
