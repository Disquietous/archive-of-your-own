import SwiftUI

/// Following: every author, work and series the What's New check covers,
/// in alphabetical sections — avatar or glyph, "checked … ago", the bell
/// menu, and a name filter. Follows only; AO3 subscriptions show up here
/// once followed (the bell's Subscribed item). Tap opens the target.
struct AuthorsScreen: View {
    @Environment(AppTheme.self) private var theme
    @Environment(AppState.self) private var state
    @Environment(NavigationState.self) private var nav
    @Environment(FollowModel.self) private var follows
    @Environment(LibraryListModel.self) private var lists

    @State private var newAuthor = ""
    @FocusState private var followFocused: Bool

    private struct Entry: Identifiable {
        let target: FollowModel.Target
        var id: String { target.key }
    }

    private func entries(_ kind: FollowModel.Kind) -> [Entry] {
        let needle = lists.authorsListFilter.trimmingCharacters(in: .whitespaces).lowercased()
        return follows.follows(of: kind)
            .map { Entry(target: FollowModel.Target(kind: kind, id: $0.targetId, name: $0.name)) }
            .filter { needle.isEmpty
                || $0.target.name.lowercased().contains(needle)
                || $0.target.id.lowercased().contains(needle) }
            .sorted { $0.target.name.localizedCaseInsensitiveCompare($1.target.name) == .orderedAscending }
    }

    private var sections: [(title: String, entries: [Entry])] {
        [("Authors", entries(.author)), ("Works", entries(.work)), ("Series", entries(.series))]
            .filter { !$0.1.isEmpty }
    }

    private var totalCount: Int { follows.checkedFollowCount }

    var body: some View {
        @Bindable var lists = lists
        ZStack(alignment: .top) {
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    if lists.showFollowAuthorField {
                        followField
                    }
                    if totalCount > 6 {
                        ListFilterField(text: $lists.authorsListFilter, placeholder: "Filter by name")
                    }

                    if sections.isEmpty {
                        EmptyStateView(systemImage: "bell", title: totalCount == 0 ? "Nothing followed yet" : "No matches",
                                       subtitle: """
                                           Follow an author by username, or use the bell on any author, work or \
                                           series. What’s New checks everything you follow.
                                           """)
                            .padding(.top, 32)
                    } else {
                        ForEach(sections, id: \.title) { section in
                            Text(section.title.uppercased())
                                .font(.custom("HankenGrotesk", size: 11).weight(.semibold))
                                .tracking(0.6)
                                .foregroundStyle(theme.ink3)
                                .padding(.top, 8)
                            VStack(spacing: 0) {
                                ForEach(section.entries) { entry in
                                    row(entry)
                                    if entry.id != section.entries.last?.id {
                                        Divider().padding(.leading, 66)
                                    }
                                }
                            }
                            .background(theme.surface)
                            .clipShape(RoundedRectangle(cornerRadius: Radius.card))
                            .overlay(RoundedRectangle(cornerRadius: Radius.card).stroke(theme.line, lineWidth: 1))
                        }
                    }
                }
                .padding(.horizontal, theme.pad)
                .padding(.bottom, 32)
            }
            .contentMargins(.top, ScreenChromeMetrics.height, for: .scrollContent)
            .scrollDismissesKeyboard(.interactively)

            ScreenChrome(title: "Following", subtitle: totalCount == 1 ? "1 followed" : "\(totalCount) followed") {
                ChromeIconButton(symbol: "plus", tint: lists.showFollowAuthorField ? theme.accent : nil) {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        lists.showFollowAuthorField.toggle()
                    }
                    followFocused = lists.showFollowAuthorField
                }
            }
        }
        .libraryScreen()
        .onAppear { state.loadFollowLastChecked() }
    }

    private var followField: some View {
        HStack(spacing: 8) {
            Image(systemName: "plus")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(theme.ink3)
            TextField("Follow an author (AO3 username)", text: $newAuthor)
                .textFieldStyle(.plain)
                .font(.custom("HankenGrotesk", size: 14))
                .foregroundStyle(theme.ink)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
                .focused($followFocused)
                .submitLabel(.done)
                .onSubmit {
                    let name = newAuthor.trimmingCharacters(in: .whitespaces)
                    if !name.isEmpty { follows.follow(.author(name)) }
                    newAuthor = ""
                    lists.showFollowAuthorField = false
                }
        }
        .padding(.horizontal, 12)
        .frame(height: 42)
        .background(theme.surface)
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10)
            .stroke(followFocused ? theme.accent : theme.line, lineWidth: 1))
    }

    /// Authors: the DB-cached AO3 avatar, the letter disc until (or
    /// unless) the one-time fetch delivers. Works and series: a glyph.
    private func avatar(_ target: FollowModel.Target) -> some View {
        Group {
            if target.kind == .author {
                if theme.imageAutoLoad, let data = state.authorAvatars[target.id], let image = UIImage(data: data) {
                    Image(uiImage: image)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                } else {
                    Circle()
                        .fill(Fandom.spineColorForHue(abs(target.name.hashValue % 360)))
                        .overlay {
                            Text(String(target.name.prefix(1)).uppercased())
                                .font(Typography.workTitle())
                                .foregroundStyle(theme.onAccent)
                        }
                }
            } else {
                Circle()
                    .fill(theme.bg)
                    .overlay {
                        Image(systemName: target.kind == .work ? "doc.text" : "books.vertical")
                            .font(.system(size: 15, weight: .medium))
                            .foregroundStyle(theme.accent)
                    }
            }
        }
        .frame(width: 40, height: 40)
        .clipShape(Circle())
        .onAppear { if theme.imageAutoLoad && target.kind == .author { state.loadAuthorAvatar(target.id) } }
        .onChange(of: theme.imageAutoLoad) { _, on in if on && target.kind == .author { state.loadAuthorAvatar(target.id) } }
    }

    private func open(_ target: FollowModel.Target) {
        switch target.kind {
        case .author: nav.libraryPath.append(AppDestination.authorWorks(username: target.id))
        case .work: nav.openWork(target.id)
        case .series: nav.openSubscriptionWorks(id: target.id, name: target.name, subType: "series")
        case .fandom: break
        }
    }

    private func row(_ entry: Entry) -> some View {
        let target = entry.target
        let lastChecked = follows.lastChecked(target)
        let subscribed = follows.isSubscribed(target)
        return HStack(spacing: 12) {
            Button {
                open(target)
            } label: {
                HStack(spacing: 12) {
                    avatar(target)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(target.name)
                            .font(.custom("HankenGrotesk", size: 15).weight(.semibold))
                            .foregroundStyle(theme.ink)
                            .lineLimit(1)
                        HStack(spacing: 6) {
                            if subscribed { Text("Subscribed on AO3 ·") }
                            if follows.isNotFound(target) {
                                Text("Not Found")
                            } else if let lastChecked, let rel = DBTimestamp.relative(lastChecked) {
                                Text("Checked \(rel)")
                            } else {
                                Text("Not checked yet")
                            }
                        }
                        .font(.custom("HankenGrotesk", size: 12))
                        .foregroundStyle(theme.ink3)
                        .lineLimit(1)
                    }
                    Spacer()
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            FollowBellMenu(target: target)
            Image(systemName: "chevron.right")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(theme.ink3)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
    }
}
