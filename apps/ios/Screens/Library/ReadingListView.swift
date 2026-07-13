import SwiftUI

struct ReadingListView: View {
    @Environment(AppTheme.self) private var theme
    @Environment(AppState.self) private var state
    @Environment(NavigationState.self) private var nav
    @Environment(\.dismiss) private var dismiss

    let listID: Int64
    let listName: String

    @State private var showRenameDialog = false
    @State private var renameText = ""
    @State private var showDeleteConfirm = false

    private var works: [Work] {
        state.worksInReadingList(listID)
    }

    var body: some View {
        ZStack(alignment: .top) {
            ScrollView {
                VStack(alignment: .leading, spacing: theme.rowGap) {
                    Spacer()
                        .frame(height: 56)

                    if works.isEmpty {
                        EmptyStateView(
                            systemImage: "text.badge.plus",
                            title: "No works yet",
                            subtitle: "Add works to this list from any work detail page."
                        )
                        .padding(.top, 40)
                    } else {
                        LazyVStack(spacing: theme.rowGap) {
                            ForEach(works) { work in
                                WorkCardView(
                                    work: work,
                                    blurExplicit: state.hideExplicit && work.rating == .explicit,
                                    onTap: { nav.openWork(work.id) }
                                )
                                .swipeActions(edge: .trailing) {
                                    Button(role: .destructive) {
                                        state.removeFromReadingList(listID, workId: work.id)
                                    } label: {
                                        Label("Remove", systemImage: "minus.circle")
                                    }
                                }
                            }
                        }
                    }
                }
                .padding(.horizontal, theme.pad)
            }

            topChrome
        }
        .background(theme.bg)
        .navigationBarBackButtonHidden(true)
        .toolbar(.hidden, for: .tabBar)
        .toolbar(.hidden, for: .navigationBar)
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

    private var topChrome: some View {
        HStack(spacing: 10) {
            Button { dismiss() } label: {
                Image(systemName: "chevron.left")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(theme.ink)
                    .frame(width: 36, height: 36)
            }
            .buttonStyle(IconButtonPressStyle())

            Text(listName)
                .font(Typography.uiBody())
                .foregroundStyle(theme.ink)
                .lineLimit(1)

            Spacer()

            Menu {
                Button {
                    renameText = listName
                    showRenameDialog = true
                } label: {
                    Label("Rename", systemImage: "pencil")
                }
                Button(role: .destructive) {
                    showDeleteConfirm = true
                } label: {
                    Label("Delete List", systemImage: "trash")
                }
            } label: {
                Image(systemName: "ellipsis")
                    .font(.system(size: 17, weight: .medium))
                    .foregroundStyle(theme.ink2)
                    .frame(width: 36, height: 36)
            }

            PrivacyPillView {
                nav.presentedSheet = .privacy
            }
        }
        .padding(.horizontal, theme.pad)
        .padding(.top, 8)
        .padding(.bottom, 8)
        .background(
            theme.bg.opacity(0.95)
                .shadow(.drop(color: .black.opacity(0.05), radius: 4, y: 2))
        )
    }
}
