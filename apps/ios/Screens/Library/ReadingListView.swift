import SwiftUI

/// One reading list's works — the generic list screen over the list's
/// membership, with rename/delete in the menu and swipe-to-remove rows.
struct ReadingListView: View {
    @Environment(AppState.self) private var state
    @Environment(\.dismiss) private var dismiss

    let listID: Int64
    let listName: String

    @State private var showRenameDialog = false
    @State private var renameText = ""
    @State private var showDeleteConfirm = false

    private var currentName: String {
        state.readingLists.first { $0.id == listID }?.name ?? listName
    }

    var body: some View {
        WorkListScreen(
            section: .readingLists,
            title: currentName,
            rawWorks: { state.worksInReadingList(listID) },
            empty: .init(systemImage: "text.badge.plus", title: "No works yet",
                         subtitle: "Add works to this list from any work’s menu."),
            swipe: .init(label: "Remove", systemImage: "minus.circle") { work in
                state.removeFromReadingList(listID, workId: work.id)
            },
            menuItems: AnyView(Group {
                Button {
                    renameText = currentName
                    showRenameDialog = true
                } label: {
                    Label("Rename", systemImage: "pencil")
                }
                Button(role: .destructive) {
                    showDeleteConfirm = true
                } label: {
                    Label("Delete List", systemImage: "trash")
                }
            })
        )
        .alert("Rename List", isPresented: $showRenameDialog) {
            TextField("List name", text: $renameText)
            Button("Rename") {
                let trimmed = renameText.trimmingCharacters(in: .whitespaces)
                if !trimmed.isEmpty {
                    state.renameReadingList(listID, name: trimmed)
                }
            }
            Button("Cancel", role: .cancel) {}
        }
        .alert("Delete List?", isPresented: $showDeleteConfirm) {
            Button("Delete", role: .destructive) {
                state.deleteReadingList(listID)
                dismiss()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This will delete the reading list. Works in the list will not be removed from your library.")
        }
    }
}
