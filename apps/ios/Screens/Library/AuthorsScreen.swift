import SwiftUI

/// Authors followed locally and subscribed on AO3, in one alphabetical
/// list: avatar, source line, follow bell, "checked … ago", username
/// filter, and a source filter. Tap opens the author's works.
struct AuthorsScreen: View {
    @Environment(AppTheme.self) private var theme
    @Environment(AppState.self) private var state
    @Environment(NavigationState.self) private var nav
    @Environment(FollowModel.self) private var follows
    @Environment(LibraryListModel.self) private var lists

    @State private var newAuthor = ""
    @FocusState private var followFocused: Bool

    private struct Entry: Identifiable {
        let name: String
        let username: String
        let source: String
        var id: String { name }
    }

    private var authors: [Entry] {
        var seen = Set<String>()
        var result: [Entry] = []
        if lists.authorsIncludeFollowed {
            for name in follows.followedAuthorNames where seen.insert(name).inserted {
                result.append(Entry(name: name, username: name, source: "Followed"))
            }
        }
        if lists.authorsIncludeSubscribed {
            for sub in state.followedAuthors where seen.insert(sub.name).inserted {
                result.append(Entry(name: sub.name, username: sub.id, source: "Subscribed on AO3"))
            }
        }
        result.sort { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        let needle = lists.authorsListFilter.trimmingCharacters(in: .whitespaces).lowercased()
        guard !needle.isEmpty else { return result }
        return result.filter { $0.name.lowercased().contains(needle) || $0.username.lowercased().contains(needle) }
    }

    private var totalCount: Int {
        follows.followedAuthorNames.count + state.followedAuthors.count
    }

    var body: some View {
        @Bindable var lists = lists
        ZStack(alignment: .top) {
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    if lists.showFollowAuthorField {
                        followField
                    }
                    if totalCount > 6 {
                        ListFilterField(text: $lists.authorsListFilter, placeholder: "Filter by username")
                    }

                    if authors.isEmpty {
                        EmptyStateView(systemImage: "person", title: "No authors yet",
                                       subtitle: "Follow an author by username, or sign in to see your AO3 author subscriptions.")
                            .padding(.top, 32)
                    } else {
                        VStack(spacing: 0) {
                            ForEach(authors) { author in
                                authorRow(author)
                                if author.id != authors.last?.id {
                                    Divider().padding(.leading, 66)
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

            ScreenChrome(title: "Authors", subtitle: totalCount == 1 ? "1 author" : "\(totalCount) authors") {
                ChromeIconButton(symbol: "plus", tint: lists.showFollowAuthorField ? theme.accent : nil) {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        lists.showFollowAuthorField.toggle()
                    }
                    followFocused = lists.showFollowAuthorField
                }
                Menu {
                    Toggle("Include Followed", isOn: $lists.authorsIncludeFollowed)
                    Toggle("Include Subscribed", isOn: $lists.authorsIncludeSubscribed)
                } label: {
                    let narrowed = !(lists.authorsIncludeFollowed && lists.authorsIncludeSubscribed)
                    Image(systemName: narrowed ? "line.3.horizontal.decrease.circle.fill"
                                               : "line.3.horizontal.decrease.circle")
                        .font(.system(size: 16, weight: .medium))
                        .foregroundStyle(narrowed ? theme.accent : theme.ink2)
                        .frame(width: 36, height: 36)
                }
            }
        }
        .libraryScreen()
        .onAppear { state.loadSubscriptionLastChecked() }
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
                    follows.followAuthor(newAuthor)
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

    /// DB-cached AO3 avatar; the letter disc shows until (or unless) the
    /// one-time fetch delivers.
    private func avatar(_ entry: Entry) -> some View {
        Group {
            if let data = state.authorAvatars[entry.username], let image = UIImage(data: data) {
                Image(uiImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            } else {
                Circle()
                    .fill(Fandom.spineColorForHue(abs(entry.name.hashValue % 360)))
                    .overlay {
                        Text(String(entry.name.prefix(1)).uppercased())
                            .font(Typography.workTitle())
                            .foregroundStyle(theme.onAccent)
                    }
            }
        }
        .frame(width: 40, height: 40)
        .clipShape(Circle())
        .onAppear { state.loadAuthorAvatar(entry.username) }
    }

    private func authorRow(_ entry: Entry) -> some View {
        // All author checks run under sub_type "author" whether the row is a
        // local follow or an AO3 subscription.
        let lastChecked = state.subscriptionLastChecked["author:\(entry.username)"]
        let followState = follows.authorFollowState(entry.name)
        return Button {
            nav.libraryPath.append(AppDestination.authorWorks(username: entry.username))
        } label: {
            HStack(spacing: 12) {
                avatar(entry)
                VStack(alignment: .leading, spacing: 2) {
                    Text(entry.name)
                        .font(.custom("HankenGrotesk", size: 15).weight(.semibold))
                        .foregroundStyle(theme.ink)
                        .lineLimit(1)
                    HStack(spacing: 6) {
                        Text(entry.source)
                        if let lastChecked, let rel = DBTimestamp.relative(lastChecked) {
                            Text("· Checked \(rel)")
                        }
                    }
                    .font(.custom("HankenGrotesk", size: 12))
                    .foregroundStyle(theme.ink3)
                    .lineLimit(1)
                }
                Spacer()
                Button {
                    follows.toggleAuthorFollow(entry.name)
                } label: {
                    Image(systemName: followState.shaded ? "bell.fill" : "bell")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(followState.shaded ? theme.accent : theme.ink3)
                        .frame(width: 28, height: 28)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                Image(systemName: "chevron.right")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(theme.ink3)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 11)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
