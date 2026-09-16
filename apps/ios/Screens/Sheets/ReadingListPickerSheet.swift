import SwiftUI

/// Find-or-create reading list picker for one work: type to filter the
/// lists, tap to toggle membership, and when the typed name matches
/// nothing a Create row makes the list with this work already in it. The
/// iOS counterpart of the macOS `ReadingListPopover`.
struct ReadingListPickerSheet: View {
    @Environment(AppTheme.self) private var theme
    @Environment(AppState.self) private var state
    @Environment(\.dismiss) private var dismiss

    let workID: String

    @State private var term = ""
    @State private var memberListIds: Set<Int64> = []
    @FocusState private var searchFocused: Bool

    private var workId: UInt64? { UInt64(workID) }

    private var filteredLists: [UReadingList] {
        let needle = term.trimmingCharacters(in: .whitespaces)
        guard !needle.isEmpty else { return state.readingLists }
        return state.readingLists.filter {
            $0.name.localizedCaseInsensitiveContains(needle)
        }
    }

    private var canCreateTyped: Bool {
        let needle = term.trimmingCharacters(in: .whitespaces)
        guard !needle.isEmpty else { return false }
        return !state.readingLists.contains {
            $0.name.caseInsensitiveCompare(needle) == .orderedSame
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            RoundedRectangle(cornerRadius: 3)
                .fill(theme.line2)
                .frame(width: 36, height: 5)
                .padding(.top, 10)
                .padding(.bottom, 12)

            HStack {
                Text("Reading Lists")
                    .font(Typography.sheetTitle())
                    .foregroundStyle(theme.ink)
                Spacer()
                Button { dismiss() } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(theme.ink3)
                        .frame(width: 32, height: 32)
                        .background(theme.surface2)
                        .clipShape(Circle())
                }
            }
            .padding(.horizontal, theme.pad)
            .padding(.bottom, 12)

            TextField("Find or create a list…", text: $term)
                .font(Typography.uiBody())
                .foregroundStyle(theme.ink)
                .padding(.horizontal, 12)
                .frame(height: 40)
                .background(theme.surface2)
                .clipShape(RoundedRectangle(cornerRadius: 10))
                .padding(.horizontal, theme.pad)
                .focused($searchFocused)
                .submitLabel(.done)
                .onSubmit { createTypedIfPossible() }

            ScrollView {
                VStack(spacing: 0) {
                    ForEach(filteredLists, id: \.id) { list in
                        listRow(list)
                        Divider().foregroundStyle(theme.line)
                    }
                    if canCreateTyped {
                        createRow
                    } else if filteredLists.isEmpty {
                        Text("No lists yet — type a name to create one.")
                            .font(Typography.uiSmall())
                            .foregroundStyle(theme.ink3)
                            .padding(16)
                    }
                }
                .padding(.horizontal, theme.pad)
                .padding(.top, 8)
            }
        }
        .background(theme.surface)
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.hidden)
        .onAppear {
            if let workId {
                memberListIds = Set(state.readingListIDs(forWork: workId))
            }
            searchFocused = true
        }
    }

    private func listRow(_ list: UReadingList) -> some View {
        let member = memberListIds.contains(list.id)
        return Button {
            guard workId != nil else { return }
            if member {
                state.removeFromReadingList(list.id, workId: workID)
                memberListIds.remove(list.id)
            } else {
                state.addToReadingList(list.id, workId: workID)
                memberListIds.insert(list.id)
            }
        } label: {
            HStack(spacing: 12) {
                Image(systemName: "books.vertical")
                    .font(.system(size: 14, weight: .medium))
                    .frame(width: 20)
                    .foregroundStyle(theme.ink3)
                Text(list.name)
                    .font(Typography.uiBody())
                    .foregroundStyle(theme.ink)
                    .lineLimit(1)
                Spacer(minLength: 8)
                if member {
                    Image(systemName: "checkmark")
                        .font(.system(size: 13, weight: .bold))
                        .foregroundStyle(theme.accent)
                }
            }
            .frame(height: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(member ? "Remove from \(list.name)" : "Add to \(list.name)")
    }

    private var createRow: some View {
        Button {
            createTypedIfPossible()
        } label: {
            HStack(spacing: 12) {
                Image(systemName: "plus")
                    .font(.system(size: 13, weight: .semibold))
                    .frame(width: 20)
                    .foregroundStyle(theme.accent)
                Text("Create “\(term.trimmingCharacters(in: .whitespaces))”")
                    .font(Typography.uiBody())
                    .foregroundStyle(theme.accent)
                    .lineLimit(1)
                Spacer(minLength: 8)
            }
            .frame(height: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func createTypedIfPossible() {
        guard canCreateTyped else { return }
        let name = term.trimmingCharacters(in: .whitespaces)
        let listId = state.createReadingList(name)
        if listId >= 0 {
            state.addToReadingList(listId, workId: workID)
            memberListIds.insert(listId)
        }
        term = ""
    }
}
