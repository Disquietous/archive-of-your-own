import AppKit
import SwiftUI

// MARK: - Author collections (a user's /collections, in the reading pane)

struct AuthorCollectionsView: View {
    @Bindable var theme: AppTheme
    @Bindable var appState: AppState
    @Bindable var model: MacAppModel

    var body: some View {
        let _ = theme.uiFontScale  // track app text size so fonts refresh live
        ScrollView {
            VStack(spacing: 0) {
                if model.author.collections.isEmpty {
                    if model.author.isLoadingCollections {
                        LoadingStateMac(theme: theme, message: "Loading collections…",
                                        detail: "Requests are rate-limited to be kind to the archive.")
                            .frame(minHeight: 260)
                    } else if let error = model.author.collectionsError {
                        VStack(spacing: 12) {
                            EmptyStateMac(theme: theme, icon: "exclamationmark.triangle",
                                          title: "Couldn’t reach the archive", message: error)
                            loadButton("Try Again")
                        }
                        .frame(minHeight: 260)
                        .padding(.bottom, 20)
                    } else {
                        EmptyStateMac(theme: theme, icon: "square.grid.2x2",
                                      title: "No collections in your library",
                                      message: "Press ↻ above to fetch \(model.author.username ?? "this user")’s collections from AO3.")
                            .frame(minHeight: 260)
                    }
                } else {
                    ForEach(model.author.collections, id: \.name) { collection in
                        collectionRow(collection)
                    }
                    footer
                }
            }
        }
    }

    @ViewBuilder
    private var footer: some View {
        if model.author.isLoadingCollections {
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Loading more…")
                    .font(Font(MacFont.ui(12)))
                    .foregroundStyle(theme.ink3)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 16)
        } else if let error = model.author.collectionsError {
            VStack(spacing: 8) {
                Text(error)
                    .font(Font(MacFont.ui(12)))
                    .foregroundStyle(Color(hex: "CE514D"))
                    .multilineTextAlignment(.center)
                loadButton("Try Again")
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 14)
            .padding(.horizontal, 16)
        } else if model.author.collectionsHasNext {
            loadButton("Load More")
                .frame(maxWidth: .infinity)
                .padding(.vertical, 14)
        }
    }

    private func loadButton(_ label: String) -> some View {
        Button {
            model.author.loadMoreCollections()
        } label: {
            Text(label)
                .font(Font(MacFont.ui(12.5, weight: .semibold)))
                .foregroundStyle(theme.accent)
                .padding(.horizontal, 14)
                .padding(.vertical, 6)
                .background(theme.surface)
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(theme.line, lineWidth: 1))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func collectionRow(_ collection: UCollection) -> some View {
        Button {
            // Open the collection through the shared search flow: the
            // works/bookmarks panes render in the Search section.
            let search = model.search
            model.goSection(.search)
            search.scope = .collections
            search.startCollectionQuery(collection.name,
                                        title: collection.title,
                                        workCount: collection.workCount,
                                        bookmarkedCount: collection.bookmarkedCount,
                                        appState: appState)
        } label: {
            HStack(spacing: 12) {
                Image(systemName: "square.grid.2x2")
                    .font(.system(size: 13, weight: .medium))
                    .frame(width: 18)
                    .foregroundStyle(theme.accent)
                VStack(alignment: .leading, spacing: 2) {
                    Text(collection.title.isEmpty ? collection.name : collection.title)
                        .font(Font(MacFont.ui(14, weight: .semibold)))
                        .foregroundStyle(theme.ink)
                        .lineLimit(1)
                    Text(collectionMeta(collection))
                        .font(Font(MacFont.ui(12)))
                        .foregroundStyle(theme.ink3)
                        .lineLimit(1)
                    if !collection.maintainers.isEmpty {
                        CollectionMaintainersLine(theme: theme, model: model,
                                                  maintainers: collection.maintainers)
                    }
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
        if collection.bookmarkedCount > 0 {
            parts.append(collection.bookmarkedCount == 1
                ? "1 bookmarked item" : "\(collection.bookmarkedCount) bookmarked items")
        }
        if !collection.collectionType.isEmpty { parts.append(collection.collectionType) }
        return parts.joined(separator: " · ")
    }
}
