import AppKit
import SwiftUI

// MARK: - Following (authors, works and series the What's New check watches)

struct AuthorsList: View {
    @Bindable var theme: AppTheme
    @Bindable var appState: AppState
    @Bindable var model: MacAppModel

    @State private var newAuthor = ""
    /// Which source the typed name or link belongs to (links resolve
    /// themselves; a bare name is only a key on AO3).
    @State private var newAuthorSource = "ao3"
    @State private var followError: String?
    /// Live suggestions for what's typed: the source's own user search
    /// where it has one, the library's cached AO3 accounts otherwise.
    @State private var suggestions: [UUserHit] = []
    @State private var suggestionsTask: Task<Void, Never>?
    @State private var searching = false

    /// One kind's follows, alphabetical, narrowed by the in-list filter.
    private func rows(_ kind: FollowModel.Kind) -> [UFollow] {
        let needle = model.lists.authorsListFilter.trimmingCharacters(in: .whitespaces).lowercased()
        return model.follows.follows(of: kind)
            .filter { needle.isEmpty || $0.name.lowercased().contains(needle)
                || $0.targetId.lowercased().contains(needle) }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    var body: some View {
        let _ = theme.uiFontScale  // track app text size so fonts refresh live
        let authors = rows(.author), works = rows(.work), series = rows(.series)
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                if model.lists.showFollowAuthorField {
                    followField
                        .padding(.init(top: 12, leading: 16, bottom: 2, trailing: 16))
                }
                usernameFilterField
                    .padding(.init(top: model.lists.showFollowAuthorField ? 0 : 12,
                                   leading: 16, bottom: 2, trailing: 16))

                if authors.isEmpty && works.isEmpty && series.isEmpty {
                    EmptyStateMac(theme: theme, icon: "bell",
                                  title: "Nothing followed yet",
                                  message: "Follow an author by AO3 username or by profile link from any source, or use a bell on any author, work or series. What’s New checks what you follow.")
                        .frame(minHeight: 260)
                } else {
                    VStack(alignment: .leading, spacing: 0) {
                        section("Authors", authors)
                        section("Works", works)
                        section("Series", series)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func section(_ title: String, _ follows: [UFollow]) -> some View {
        if !follows.isEmpty {
            Text(title.uppercased())
                .font(Font(MacFont.ui(10.5, weight: .semibold)))
                .tracking(0.6)
                .foregroundStyle(theme.ink3)
                .padding(.init(top: 12, leading: 16, bottom: 4, trailing: 16))
            ForEach(follows, id: \.targetId) { follow in
                followRow(follow)
            }
        }
    }

    /// Sources an author can be followed on: those with a listing to
    /// check, or a user search to find them by.
    private var sources: [SourceCapabilities] {
        appState.bridge.listSources().filter { $0.authorListings || $0.userSearch || $0.id == "ao3" }
    }

    private var selectedSource: SourceCapabilities? { sources.first { $0.id == newAuthorSource } }

    private var newAuthorPlaceholder: String {
        if selectedSource?.userSearch == true { return "Follow an author — name or profile link" }
        return newAuthorSource == "ao3" ? "Follow an author — username or profile link" : "Follow an author — paste a profile link"
    }

    private var followField: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 7) {
                Image(systemName: "plus")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(theme.ink3)
                TextField(newAuthorPlaceholder, text: $newAuthor)
                    .textFieldStyle(.plain)
                    .font(Font(MacFont.ui(12.5)))
                    .foregroundStyle(theme.ink)
                    .onSubmit(submitFollow)
                    .onChange(of: newAuthor) { _, text in scheduleSuggestions(for: text) }
                    .onChange(of: newAuthorSource) { _, _ in scheduleSuggestions(for: newAuthor) }
                if searching {
                    ProgressView().controlSize(.small)
                }
                Picker("", selection: $newAuthorSource) {
                    ForEach(sources, id: \.id) { source in
                        Text(source.name).tag(source.id)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .frame(width: 150)
                .help("The site the author is on")
            }
            .padding(.horizontal, 10)
            .frame(height: 32)
            .background(theme.surface)
            .clipShape(RoundedRectangle(cornerRadius: 9))
            .overlay(RoundedRectangle(cornerRadius: 9).stroke(theme.line, lineWidth: 1))
            if !suggestions.isEmpty {
                suggestionList
            }
            if let followError {
                Text(followError)
                    .font(Font(MacFont.ui(11)))
                    .foregroundStyle(theme.ink3)
                    .padding(.leading, 4)
            }
        }
    }

    /// Matching users under the field; a click follows that user.
    private var suggestionList: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(suggestions, id: \.sourceId) { hit in
                Button {
                    follow(hit: hit)
                } label: {
                    HStack(spacing: 10) {
                        Circle()
                            .fill(Fandom.spineColorForHue(abs(hit.username.hashValue % 360)))
                            .frame(width: 24, height: 24)
                            .overlay {
                                Text(String(hit.username.prefix(1)).uppercased())
                                    .font(Font(MacFont.serif(12, weight: .semibold)))
                                    .foregroundStyle(theme.onAccent)
                            }
                        Text(hit.username)
                            .font(Font(MacFont.ui(12.5, weight: .medium)))
                            .foregroundStyle(theme.ink)
                            .lineLimit(1)
                        Spacer()
                        Text(appState.bridge.sourceCapabilities(hit.source)?.name ?? hit.source)
                            .font(Font(MacFont.ui(10.5)))
                            .foregroundStyle(theme.ink3)
                    }
                    .padding(.horizontal, 10)
                    .frame(height: 30)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .background(theme.surface)
        .clipShape(RoundedRectangle(cornerRadius: 9))
        .overlay(RoundedRectangle(cornerRadius: 9).stroke(theme.line, lineWidth: 1))
    }

    /// Debounced (300 ms, like the site's own widget) suggestions for the
    /// typed text. A pasted link gets no suggestions — it resolves itself.
    private func scheduleSuggestions(for text: String) {
        suggestionsTask?.cancel()
        let query = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard query.count >= 2, !query.contains("/") else {
            suggestions = []
            searching = false
            return
        }
        let source = newAuthorSource
        let bridge = appState.bridge
        suggestionsTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled else { return }
            if bridge.sourceCapabilities(source)?.userSearch == true {
                searching = true
                defer { searching = false }
                let hits = (try? await bridge.searchUsers(source: source, query: query)) ?? []
                guard !Task.isCancelled, newAuthor.trimmingCharacters(in: .whitespacesAndNewlines) == query else { return }
                suggestions = hits
            } else if source == "ao3" {
                // AO3 has no live people search here; the library's cached
                // accounts are the suggestions, and any typed name is a key.
                suggestions = bridge.searchLibraryUsers(query, limit: 8).map {
                    UUserHit(source: "ao3", sourceId: $0, username: $0, profileUrl: "", avatarUrl: "")
                }
            } else {
                suggestions = []
            }
        }
    }

    /// Follow a suggested user: its row (created when never seen) carries
    /// the name and profile the search showed.
    private func follow(hit: UUserHit) {
        followError = nil
        let id: UInt64?
        if hit.source == "ao3" {
            id = appState.userID(forAO3Username: hit.username)
        } else {
            id = appState.bridge.ensureUser(source: hit.source, sourceID: hit.sourceId, url: hit.profileUrl, username: hit.username)
        }
        guard let id else { followError = "Couldn’t add that author."; return }
        model.follows.follow(.author(id: id, name: hit.username))
        Task { @MainActor in
            await appState.loadUser(id)
            model.follows.reload()
        }
        newAuthor = ""
        suggestions = []
        model.lists.showFollowAuthorField = false
    }

    /// Follow what was typed: a profile link from any source resolves to
    /// its user (created when never seen, named from the link until the
    /// profile is fetched); a bare name is an AO3 account name, since AO3
    /// is the one source whose names are keys.
    private func submitFollow() {
        let input = newAuthor.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !input.isEmpty else { return }
        followError = nil
        let bridge = appState.bridge
        var target: FollowModel.Target?
        if let link = bridge.resolveUserLink(input) {
            let slug = URL(string: link.url)?.pathComponents.last(where: { $0 != "/" && !$0.isEmpty }) ?? link.externalId
            let name = link.source == "ao3" ? link.externalId : slug.replacingOccurrences(of: "-", with: "_")
            if let id = bridge.ensureUser(source: link.source, sourceID: link.externalId, url: link.url, username: name) {
                target = .author(id: id, name: name)
                // The link names the user by key or slug; the profile gives
                // the real name.
                Task { @MainActor in
                    await appState.loadUser(id)
                    model.follows.reload()
                }
            }
        } else if newAuthorSource == "ao3" {
            target = model.follows.ao3AuthorTarget(input, ensure: true)
        } else if let first = suggestions.first {
            // Enter on a searched name takes the top match, like the site.
            follow(hit: first)
            return
        } else {
            let site = selectedSource?.name ?? newAuthorSource
            followError = selectedSource?.userSearch == true
                ? "No \(site) user matches that name yet — keep typing, or paste a profile link."
                : "\(site) authors are followed by profile link — paste the link to their profile."
            return
        }
        guard let target else {
            followError = "Couldn’t recognise that as an author."
            return
        }
        model.follows.follow(target)
        newAuthor = ""
        suggestions = []
        model.lists.showFollowAuthorField = false
    }

    private var usernameFilterField: some View {
        HStack(spacing: 7) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(theme.ink3)
            TextField("Filter by name", text: Binding(
                get: { model.lists.authorsListFilter },
                set: { model.lists.authorsListFilter = $0 }))
                .textFieldStyle(.plain)
                .font(Font(MacFont.ui(12.5)))
                .foregroundStyle(theme.ink)
            if !model.lists.authorsListFilter.isEmpty {
                Button {
                    model.lists.authorsListFilter = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 12))
                        .foregroundStyle(theme.ink3)
                }
                .buttonStyle(.plain)
                .help("Clear filter")
            }
        }
        .padding(.horizontal, 10)
        .frame(height: 32)
        .background(theme.surface)
        .clipShape(RoundedRectangle(cornerRadius: 9))
        .overlay(RoundedRectangle(cornerRadius: 9).stroke(theme.line, lineWidth: 1))
    }

    private func userID(_ follow: UFollow) -> UInt64? {
        follow.kind == "author" ? UInt64(follow.targetId) : nil
    }

    /// The follow's display name: the user's current name once known.
    private func displayName(_ follow: UFollow) -> String {
        userID(follow).flatMap { appState.user($0)?.username } ?? follow.name
    }

    /// Cached avatar for authors (the letter disc shows until, or unless,
    /// the one-time fetch delivers); a glyph disc for works/series.
    private func avatar(_ follow: UFollow) -> some View {
        Group {
            if let id = userID(follow), theme.imageAutoLoad,
               let data = appState.userAvatar(id), let image = NSImage(data: data) {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            } else {
                Circle()
                    .fill(Fandom.spineColorForHue(abs(follow.name.hashValue % 360)))
                    .overlay {
                        if follow.kind == "author" {
                            Text(String(follow.name.prefix(1)).uppercased())
                                .font(Font(MacFont.serif(18, weight: .semibold)))
                                .foregroundStyle(theme.onAccent)
                        } else {
                            Image(systemName: follow.kind == "work" ? "book.closed" : "books.vertical")
                                .font(.system(size: 15, weight: .semibold))
                                .foregroundStyle(theme.onAccent)
                        }
                    }
            }
        }
        .frame(width: 40, height: 40)
        .clipShape(Circle())
        .onAppear {
            if let id = userID(follow), theme.imageAutoLoad { appState.loadUserAvatar(id) }
        }
        .onChange(of: theme.imageAutoLoad) { _, on in
            if on, let id = userID(follow) { appState.loadUserAvatar(id) }
        }
    }

    private func subtitle(_ follow: UFollow, _ target: FollowModel.Target) -> String {
        let kind = switch follow.kind {
        case "work": "Work"
        case "series": "Series"
        default: "Author"
        }
        // Where it lives, when not AO3; AO3 subscription state when it is.
        if !follow.source.isEmpty && follow.source != "ao3" {
            let site = appState.bridge.sourceCapabilities(follow.source)?.name ?? follow.source
            return "\(kind) · \(site)"
        }
        return model.follows.isSubscribed(target) ? "\(kind) · Subscribed on AO3" : kind
    }

    private func open(_ follow: UFollow) {
        switch follow.kind {
        case "work": model.openWorkByID(follow.targetId)
        case "series": model.openSeries(id: follow.targetId, name: follow.name)
        default: if let id = userID(follow) { model.openAuthor(userID: id) }
        }
    }

    private func followRow(_ follow: UFollow) -> some View {
        let kind = FollowModel.Kind(rawValue: follow.kind) ?? .author
        let target = FollowModel.Target(kind: kind, id: follow.targetId, name: displayName(follow))
        // Same selection treatment as the work lists: accent-soft fill
        // with a 3pt accent bar on the leading edge.
        let selected = kind == .author && model.author.userID == userID(follow)
        let checkedLabel = model.follows.isNotFound(target)
            ? "Not Found" : follow.lastCheckedAt.map { "Checked \(Fmt.relativeTime($0))" }
        return Button {
            open(follow)
        } label: {
            HStack(spacing: 12) {
                avatar(follow)
                VStack(alignment: .leading, spacing: 1) {
                    HStack(spacing: 6) {
                        SourceBadgeView(source: follow.source)
                            .foregroundStyle(theme.ink2)
                        Text(displayName(follow))
                            .font(Font(MacFont.ui(14.5, weight: .semibold)))
                            .foregroundStyle(theme.ink)
                            .lineLimit(1)
                    }
                    Text(subtitle(follow, target))
                        .font(Font(MacFont.ui(12)))
                        .foregroundStyle(theme.ink3)
                }
                Spacer()
                FollowBell(theme: theme, follows: model.follows, target: target,
                           shaded: model.follows.isShaded(target))
                    .frame(width: 20, height: 20)
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
        // "Checked 2h ago" in the top-right corner — the same treatment as
        // the work rows' published/updated dates. "Not Found" instead when
        // the last check 404'd.
        .overlay(alignment: .topTrailing) {
            if let checkedLabel {
                Text(checkedLabel)
                    .font(Font(MacFont.ui(10, weight: .medium)))
                    .foregroundStyle(theme.ink3)
                    .padding(.top, 6)
                    .padding(.trailing, 16)
            }
        }
        .overlay(alignment: .bottom) { theme.line.frame(height: 1) }
    }
}
