import SwiftUI

/// Settings › iCloud Sync › Backups: the libraries the core filed away
/// before replacing one. Tap a row to restore it (confirmed); tap its
/// trash icon or swipe right to delete it (confirmed). The leading circle
/// selects rows; while any are selected a trash button in the chrome
/// deletes them all (confirmed).
struct LibraryBackupsScreen: View {
    @Environment(AppTheme.self) private var theme
    @Environment(AppState.self) private var state

    @State private var restoreCandidate: CloudLibrarySync.Backup?
    @State private var deleteCandidate: CloudLibrarySync.Backup?
    @State private var selectedBackupIDs: Set<String> = []
    @State private var confirmDeleteSelected = false

    private var sync: CloudLibrarySync { state.cloudSync }

    private static let destructiveTint = Color(hex: "CE514D")

    private var chromeSubtitle: String? {
        if sync.status == .replacing { return "Replacing the library…" }
        if !selectedBackupIDs.isEmpty { return "\(selectedBackupIDs.count) selected" }
        return nil
    }

    var body: some View {
        ZStack(alignment: .top) {
            List {
                if sync.backups.isEmpty {
                    Text("No backups yet. One is made whenever this library is replaced — by the iCloud copy, or by restoring a backup — and whenever this device replaces another device's iCloud copy.")
                        .font(Typography.uiSmall())
                        .foregroundStyle(theme.ink3)
                        .fixedSize(horizontal: false, vertical: true)
                        .listRowInsets(EdgeInsets(top: 8, leading: theme.pad, bottom: 8, trailing: theme.pad))
                        .listRowBackground(Color.clear)
                        .listRowSeparator(.hidden)
                } else {
                    ForEach(sync.backups) { backup in
                        row(backup)
                            .listRowInsets(EdgeInsets(top: theme.rowGap / 2, leading: theme.pad,
                                                      bottom: theme.rowGap / 2, trailing: theme.pad))
                            .listRowBackground(Color.clear)
                            .listRowSeparator(.hidden)
                            .swipeActions(edge: .leading, allowsFullSwipe: true) {
                                Button(role: .destructive) {
                                    deleteCandidate = backup
                                } label: {
                                    Label("Delete", systemImage: "trash")
                                }
                            }
                    }
                    Text("Restoring a backup replaces this device's library with it; the library being replaced becomes a new backup first.")
                        .font(Typography.uiCaption())
                        .foregroundStyle(theme.ink3)
                        .fixedSize(horizontal: false, vertical: true)
                        .listRowInsets(EdgeInsets(top: 12, leading: theme.pad, bottom: 8, trailing: theme.pad))
                        .listRowBackground(Color.clear)
                        .listRowSeparator(.hidden)
                }

                Color.clear
                    .frame(height: 24)
                    .listRowInsets(EdgeInsets())
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .contentMargins(.top, ScreenChromeMetrics.height, for: .scrollContent)

            ScreenChrome(title: "Backups", subtitle: chromeSubtitle) {
                if !selectedBackupIDs.isEmpty {
                    ChromeIconButton(symbol: "trash", tint: Self.destructiveTint) {
                        confirmDeleteSelected = true
                    }
                    .disabled(sync.busy)
                    .accessibilityLabel(selectedBackupIDs.count == 1 ? "Delete 1 selected backup" : "Delete \(selectedBackupIDs.count) selected backups")
                }
            }
        }
        .libraryScreen()
        .onAppear { sync.refreshBackups() }
        .onChange(of: sync.backups) { _, backups in
            // Drop selections for backups that no longer exist.
            let live = Set(backups.map(\.id))
            selectedBackupIDs = selectedBackupIDs.intersection(live)
        }
        .confirmationDialog("Restore this backup?", isPresented: Binding(
            get: { restoreCandidate != nil }, set: { if !$0 { restoreCandidate = nil } }
        ), titleVisibility: .visible) {
            Button("Restore", role: .destructive) {
                if let b = restoreCandidate { sync.restoreBackup(id: b.id) }
                restoreCandidate = nil
            }
            Button("Cancel", role: .cancel) { restoreCandidate = nil }
        } message: {
            if let b = restoreCandidate {
                Text("This device's library will be replaced with the backup from \(Self.absolute(b.createdAt)). The current library is kept as a new backup.")
            }
        }
        .confirmationDialog("Delete this backup?", isPresented: Binding(
            get: { deleteCandidate != nil }, set: { if !$0 { deleteCandidate = nil } }
        ), titleVisibility: .visible) {
            Button("Delete", role: .destructive) {
                if let b = deleteCandidate { sync.deleteBackup(id: b.id) }
                deleteCandidate = nil
            }
            Button("Cancel", role: .cancel) { deleteCandidate = nil }
        } message: {
            if let b = deleteCandidate {
                Text("The backup from \(Self.absolute(b.createdAt)) is deleted. This can't be undone.")
            }
        }
        .confirmationDialog(selectedBackupIDs.count == 1 ? "Delete the selected backup?" : "Delete \(selectedBackupIDs.count) selected backups?",
                            isPresented: $confirmDeleteSelected, titleVisibility: .visible) {
            Button("Delete", role: .destructive) {
                let ids = sync.backups.map(\.id).filter { selectedBackupIDs.contains($0) }
                sync.deleteBackups(ids: ids)
                selectedBackupIDs.removeAll()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("The backup files are deleted. This can't be undone.")
        }
    }

    private func row(_ backup: CloudLibrarySync.Backup) -> some View {
        let selected = selectedBackupIDs.contains(backup.id)
        return HStack(spacing: 12) {
            Button {
                toggleSelection(backup.id)
            } label: {
                Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 20))
                    .foregroundStyle(selected ? theme.accent : theme.ink3)
                    .frame(width: 28, height: 28)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(selected ? "Deselect backup" : "Select backup")

            Button {
                guard !sync.busy else { return }
                restoreCandidate = backup
            } label: {
                HStack(spacing: 12) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(Self.absolute(backup.createdAt))
                            .font(Typography.uiBody())
                            .foregroundStyle(theme.ink)
                        Text(Self.subtitle(for: backup))
                            .font(Typography.uiCaption())
                            .foregroundStyle(theme.ink3)
                    }
                    Spacer()
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityHint("Restores this backup")

            Button {
                guard !sync.busy else { return }
                deleteCandidate = backup
            } label: {
                Image(systemName: "trash")
                    .font(.system(size: 16, weight: .medium))
                    .foregroundStyle(Self.destructiveTint)
                    .frame(width: 28, height: 28)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Delete backup")
        }
        .padding(.horizontal, theme.cardPad)
        .padding(.vertical, 12)
        .background(
            RoundedRectangle(cornerRadius: Radius.settingsGroup)
                .fill(theme.surface)
        )
        .opacity(sync.busy ? 0.5 : 1)
    }

    private func toggleSelection(_ id: String) {
        if selectedBackupIDs.contains(id) {
            selectedBackupIDs.remove(id)
        } else {
            selectedBackupIDs.insert(id)
        }
    }

    static func subtitle(for backup: CloudLibrarySync.Backup) -> String {
        var parts: [String] = []
        if !backup.reason.isEmpty { parts.append(backup.reason) }
        if !backup.sourceDevice.isEmpty { parts.append("from \(backup.sourceDevice)") }
        parts.append(ByteCountFormatter.string(fromByteCount: Int64(backup.sizeBytes), countStyle: .file))
        return parts.joined(separator: " · ")
    }

    private static func absolute(_ date: Date) -> String {
        date.formatted(date: .abbreviated, time: .shortened)
    }
}
