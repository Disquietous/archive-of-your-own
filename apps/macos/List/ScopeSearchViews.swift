import SwiftUI

/// The criteria form for the non-works search scopes (Collections,
/// Bookmarks, Tags, Users): one query field — these scopes search by name,
/// not by the works form's many criteria. Return runs the search; the
/// footer explains what the source toggle means for this scope.
struct ScopeSearchFormView: View {
    @Bindable var theme: AppTheme
    @Bindable var appState: AppState
    @Bindable var model: MacAppModel

    @FocusState private var focused: Bool

    private var placeholder: String {
        switch model.search.scope {
        case .works: ""
        case .collections: "Collection name, maintainer, or summary…"
        case .bookmarks: "Title, author, tag, or summary…"
        case .tags: "Tag name…"
        case .users: "Username…"
        }
    }

    var body: some View {
        let search = model.search
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 7) {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(theme.ink3)
                    TextField(placeholder, text: Bindable(search).scopeQuery)
                        .textFieldStyle(.plain)
                        .font(Font(MacFont.ui(13)))
                        .foregroundStyle(theme.ink)
                        .focused($focused)
                        .onSubmit { search.performScopedSearch(appState) }
                }
                .padding(.horizontal, 10)
                .frame(height: 34)
                .background(theme.surface)
                .clipShape(RoundedRectangle(cornerRadius: 9))
                .overlay(RoundedRectangle(cornerRadius: 9)
                    .stroke(focused ? theme.accent : theme.line, lineWidth: 1))

                if let notice = search.scopeNotice {
                    HStack(spacing: 8) {
                        Image(systemName: "info.circle")
                            .font(.system(size: 12, weight: .medium))
                        Text(notice)
                            .font(Font(MacFont.ui(12)))
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .foregroundStyle(theme.ink2)
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(theme.accentSoft)
                    .clipShape(RoundedRectangle(cornerRadius: 9))
                }

                Text(search.searchLibraryOnly
                    ? "Searching your library — everything the app has already fetched and cached. Nothing leaves the device."
                    : "Searching AO3 — results come from the archive over Tor.")
                    .font(Font(MacFont.ui(11.5)))
                    .foregroundStyle(theme.ink3)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(16)
            .frame(maxWidth: 560)
            .frame(maxWidth: .infinity)
        }
        .onAppear { focused = true }
    }
}

/// Results list for the scopes that don't produce works: tag, user, and
/// collection hits from the library search. Rows navigate — a tag or
/// collection opens its works (flipping to the Works tab's results), a
/// user opens the author view.
struct ScopeResultsView: View {
    @Bindable var theme: AppTheme
    @Bindable var appState: AppState
    @Bindable var model: MacAppModel

    var body: some View {
        let search = model.search
        ScrollView {
            VStack(spacing: 0) {
                switch search.scope {
                case .tags:
                    if search.tagHits.isEmpty { emptyState }
                    ForEach(Array(search.tagHits.enumerated()), id: \.offset) { _, hit in
                        row(icon: "tag", title: hit.name, sub: Self.tagTypeLabel(hit.tagType)) {
                            search.startTagQuery(hit.name, appState: appState)
                        }
                    }
                case .users:
                    if search.userHits.isEmpty { emptyState }
                    ForEach(search.userHits, id: \.self) { username in
                        row(icon: "person", title: username, sub: "AO3 user") {
                            model.openAuthor(username)
                        }
                    }
                case .collections:
                    if search.collectionHits.isEmpty { emptyState }
                    ForEach(search.collectionHits, id: \.name) { collection in
                        collectionRow(collection)
                    }
                case .works, .bookmarks:
                    EmptyView() // works results render in the works table, not here
                }
            }
        }
    }

    private var emptyState: some View {
        EmptyStateMac(theme: theme, icon: "magnifyingglass",
                      title: "No matches in your library",
                      message: "Only what the app has already cached is searched. Browse or fetch more to grow the library.")
            .frame(minHeight: 240)
    }

    static func tagTypeLabel(_ tagType: String) -> String {
        switch tagType {
        case "fandom": "Fandom"
        case "character": "Character"
        case "relationship": "Relationship"
        case "freeform": "Additional tag"
        case "creator": "Creator"
        default: tagType.capitalized
        }
    }

    private func row(icon: String, title: String, sub: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: icon)
                    .font(.system(size: 13, weight: .medium))
                    .frame(width: 18)
                    .foregroundStyle(theme.accent)
                VStack(alignment: .leading, spacing: 1) {
                    Text(title)
                        .font(Font(MacFont.ui(14, weight: .semibold)))
                        .foregroundStyle(theme.ink)
                        .lineLimit(1)
                    Text(sub)
                        .font(Font(MacFont.ui(12)))
                        .foregroundStyle(theme.ink3)
                }
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(theme.ink3)
            }
            .padding(.init(top: 11, leading: 16, bottom: 11, trailing: 16))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .overlay(alignment: .bottom) { theme.line.frame(height: 1) }
    }

    private func collectionRow(_ collection: UCollection) -> some View {
        Button {
            model.search.startCollectionQuery(collection.name, appState: appState)
        } label: {
            HStack(spacing: 12) {
                Image(systemName: "square.grid.2x2")
                    .font(.system(size: 13, weight: .medium))
                    .frame(width: 18)
                    .foregroundStyle(theme.accent)
                VStack(alignment: .leading, spacing: 2) {
                    Text(collection.title)
                        .font(Font(MacFont.ui(14, weight: .semibold)))
                        .foregroundStyle(theme.ink)
                        .lineLimit(1)
                    Text(collectionMeta(collection))
                        .font(Font(MacFont.ui(12)))
                        .foregroundStyle(theme.ink3)
                        .lineLimit(1)
                    if !collection.summary.isEmpty {
                        Text(collection.summary)
                            .font(Font(MacFont.ui(12)))
                            .foregroundStyle(theme.ink2)
                            .lineLimit(2)
                    }
                }
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(theme.ink3)
            }
            .padding(.init(top: 11, leading: 16, bottom: 11, trailing: 16))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .overlay(alignment: .bottom) { theme.line.frame(height: 1) }
    }

    private func collectionMeta(_ collection: UCollection) -> String {
        var parts = [collection.workCount == 1 ? "1 work" : "\(collection.workCount) works"]
        if !collection.collectionType.isEmpty { parts.append(collection.collectionType) }
        if !collection.maintainers.isEmpty {
            parts.append("by \(collection.maintainers.joined(separator: ", "))")
        }
        return parts.joined(separator: " · ")
    }
}
