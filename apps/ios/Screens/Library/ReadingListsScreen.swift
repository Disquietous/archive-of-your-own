import SwiftUI

/// The Reading Lists section: one row per list (stored work count, read
/// progress, top tags), a New List button, and rename/delete on each row.
struct ReadingListsScreen: View {
    @Environment(AppTheme.self) private var theme
    @Environment(AppState.self) private var state
    @Environment(NavigationState.self) private var nav

    @State private var showNewListDialog = false
    @State private var newListName = ""
    @State private var renaming: UReadingList?
    @State private var renameText = ""
    @State private var deleting: UReadingList?

    var body: some View {
        ZStack(alignment: .top) {
            ScrollView {
                VStack(alignment: .leading, spacing: theme.rowGap) {
                    if state.readingLists.isEmpty {
                        EmptyStateView(systemImage: "list.bullet.rectangle",
                                       title: "No reading lists",
                                       subtitle: "Create a list to organize your reading.")
                            .padding(.top, 40)
                    } else {
                        LazyVStack(spacing: theme.rowGap) {
                            ForEach(state.readingLists, id: \.id) { list in
                                row(list)
                            }
                        }
                    }
                }
                .padding(.horizontal, theme.pad)
                .padding(.bottom, 32)
            }
            .contentMargins(.top, ScreenChromeMetrics.height, for: .scrollContent)

            ScreenChrome(title: "Reading Lists",
                         subtitle: state.readingLists.count == 1 ? "1 list" : "\(state.readingLists.count) lists") {
                ChromeIconButton(symbol: "plus", tint: theme.accent) {
                    showNewListDialog = true
                }
            }
        }
        .libraryScreen()
        .alert("New Reading List", isPresented: $showNewListDialog) {
            TextField("List name", text: $newListName)
            Button("Create") {
                let name = newListName.trimmingCharacters(in: .whitespaces)
                if !name.isEmpty { state.createReadingList(name) }
                newListName = ""
            }
            Button("Cancel", role: .cancel) { newListName = "" }
        }
        .alert("Rename List", isPresented: Binding(
            get: { renaming != nil },
            set: { if !$0 { renaming = nil } })) {
            TextField("List name", text: $renameText)
            Button("Rename") {
                let trimmed = renameText.trimmingCharacters(in: .whitespaces)
                if let list = renaming, !trimmed.isEmpty {
                    state.renameReadingList(list.id, name: trimmed)
                }
                renaming = nil
            }
            Button("Cancel", role: .cancel) { renaming = nil }
        }
        .alert("Delete List?", isPresented: Binding(
            get: { deleting != nil },
            set: { if !$0 { deleting = nil } })) {
            Button("Delete", role: .destructive) {
                if let list = deleting { state.deleteReadingList(list.id) }
                deleting = nil
            }
            Button("Cancel", role: .cancel) { deleting = nil }
        } message: {
            Text("This will delete the reading list. Works in the list will not be removed from your library.")
        }
    }

    private func row(_ list: UReadingList) -> some View {
        let summary = state.readingListSummary(list.id)
        return Button {
            nav.openReadingList(list.id, name: list.name)
        } label: {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 5) {
                    Text(list.name)
                        .font(.custom("HankenGrotesk", size: 15).weight(.semibold))
                        .foregroundStyle(theme.ink)
                        .lineLimit(1)

                    HStack(spacing: 8) {
                        Text("\(summary.readCount)/\(summary.totalCount) read")
                            .font(.custom("HankenGrotesk", size: 12).weight(.medium))
                            .foregroundStyle(theme.ink2)
                        Text(summary.totalWords.abbreviated + " words")
                            .font(.custom("HankenGrotesk", size: 12).weight(.medium))
                            .foregroundStyle(theme.ink3)
                    }

                    if !summary.topTags.isEmpty {
                        FlowLayout(spacing: 4) {
                            ForEach(summary.topTags, id: \.self) { tag in
                                Text(tag)
                                    .font(.custom("HankenGrotesk", size: 10.5).weight(.medium))
                                    .foregroundStyle(theme.ink3)
                                    .lineLimit(1)
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 2)
                                    .background(theme.surface2)
                                    .clipShape(RoundedRectangle(cornerRadius: 4))
                            }
                        }
                    }
                }

                Spacer()

                Image(systemName: "chevron.right")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(theme.ink3)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 14)
            .background(theme.surface)
            .clipShape(RoundedRectangle(cornerRadius: Radius.card))
            .overlay(
                RoundedRectangle(cornerRadius: Radius.card)
                    .stroke(theme.line, lineWidth: 1)
            )
        }
        .buttonStyle(CardPressStyle())
        .contextMenu {
            Button {
                renameText = list.name
                renaming = list
            } label: {
                Label("Rename", systemImage: "pencil")
            }
            Button(role: .destructive) {
                deleting = list
            } label: {
                Label("Delete List", systemImage: "trash")
            }
        }
    }
}
