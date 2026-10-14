import AppKit
import SwiftUI

// MARK: - Following (authors, works and series the What's New check watches)

struct AuthorsList: View {
    @Bindable var theme: AppTheme
    @Bindable var appState: AppState
    @Bindable var model: MacAppModel

    @State private var newAuthor = ""

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
                                  message: "Follow an author by username, or use a bell on any author, work or series. What’s New checks what you follow.")
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
                    model.follows.follow(.author(newAuthor))
                    newAuthor = ""
                    model.lists.showFollowAuthorField = false
                }
        }
        .padding(.horizontal, 10)
        .frame(height: 32)
        .background(theme.surface)
        .clipShape(RoundedRectangle(cornerRadius: 9))
        .overlay(RoundedRectangle(cornerRadius: 9).stroke(theme.line, lineWidth: 1))
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

    /// DB-cached AO3 avatar for authors (the letter disc shows until, or
    /// unless, the one-time fetch delivers); a glyph disc for works/series.
    private func avatar(_ follow: UFollow) -> some View {
        Group {
            if follow.kind == "author", theme.imageAutoLoad,
               let data = appState.authorAvatars[follow.targetId], let image = NSImage(data: data) {
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
            if follow.kind == "author" && theme.imageAutoLoad { appState.loadAuthorAvatar(follow.targetId) }
        }
        .onChange(of: theme.imageAutoLoad) { _, on in
            if on && follow.kind == "author" { appState.loadAuthorAvatar(follow.targetId) }
        }
    }

    private func subtitle(_ follow: UFollow, _ target: FollowModel.Target) -> String {
        let kind = switch follow.kind {
        case "work": "Work"
        case "series": "Series"
        default: "Author"
        }
        return model.follows.isSubscribed(target) ? "\(kind) · Subscribed on AO3" : kind
    }

    private func open(_ follow: UFollow) {
        switch follow.kind {
        case "work": model.openWorkByID(follow.targetId)
        case "series": model.openSeries(id: follow.targetId, name: follow.name)
        default: model.openAuthor(follow.targetId)
        }
    }

    private func followRow(_ follow: UFollow) -> some View {
        let kind = FollowModel.Kind(rawValue: follow.kind) ?? .author
        let target = FollowModel.Target(kind: kind, id: follow.targetId, name: follow.name)
        // Same selection treatment as the work lists: accent-soft fill
        // with a 3pt accent bar on the leading edge.
        let selected = kind == .author && model.author.username == follow.targetId
        let lastChecked = follow.lastCheckedAt
        return Button {
            open(follow)
        } label: {
            HStack(spacing: 12) {
                avatar(follow)
                VStack(alignment: .leading, spacing: 1) {
                    Text(follow.name)
                        .font(Font(MacFont.ui(14.5, weight: .semibold)))
                        .foregroundStyle(theme.ink)
                        .lineLimit(1)
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
        // the work rows' published/updated dates.
        .overlay(alignment: .topTrailing) {
            if let lastChecked {
                Text("Checked \(Fmt.relativeTime(lastChecked))")
                    .font(Font(MacFont.ui(10, weight: .medium)))
                    .foregroundStyle(theme.ink3)
                    .padding(.top, 6)
                    .padding(.trailing, 16)
            }
        }
        .overlay(alignment: .bottom) { theme.line.frame(height: 1) }
    }
}
