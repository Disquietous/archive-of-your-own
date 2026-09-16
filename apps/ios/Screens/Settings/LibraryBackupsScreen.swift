import SwiftUI

/// Settings › iCloud Sync › Backups: the libraries the core filed away
/// before replacing one. Tap a row to restore it (confirmed); swipe right
/// to reveal Remove.
struct LibraryBackupsScreen: View {
    @Environment(AppTheme.self) private var theme
    @Environment(AppState.self) private var state

    @State private var restoreCandidate: CloudLibrarySync.Backup?

    private var sync: CloudLibrarySync { state.cloudSync }

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
                                    sync.deleteBackup(id: backup.id)
                                } label: {
                                    Label("Remove", systemImage: "trash")
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

            ScreenChrome(title: "Backups", subtitle: sync.status == .replacing ? "Replacing the library…" : nil)
        }
        .libraryScreen()
        .onAppear { sync.refreshBackups() }
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
                Text("This device's library will be replaced with the backup from \(b.createdAt.formatted(date: .abbreviated, time: .shortened)). The current library is kept as a new backup.")
            }
        }
    }

    private func row(_ backup: CloudLibrarySync.Backup) -> some View {
        Button {
            guard !sync.busy else { return }
            restoreCandidate = backup
        } label: {
            HStack(spacing: 12) {
                Image(systemName: "clock.arrow.circlepath")
                    .font(.system(size: 16, weight: .medium))
                    .foregroundStyle(theme.ink2)
                    .frame(width: 28)
                VStack(alignment: .leading, spacing: 2) {
                    Text(backup.createdAt.formatted(date: .abbreviated, time: .shortened))
                        .font(Typography.uiBody())
                        .foregroundStyle(theme.ink)
                    Text(Self.subtitle(for: backup))
                        .font(Typography.uiCaption())
                        .foregroundStyle(theme.ink3)
                }
                Spacer()
            }
            .padding(.horizontal, theme.cardPad)
            .padding(.vertical, 12)
            .background(
                RoundedRectangle(cornerRadius: Radius.settingsGroup)
                    .fill(theme.surface)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .opacity(sync.busy ? 0.5 : 1)
    }

    static func subtitle(for backup: CloudLibrarySync.Backup) -> String {
        var parts: [String] = []
        if !backup.reason.isEmpty { parts.append(backup.reason) }
        if !backup.sourceDevice.isEmpty { parts.append("from \(backup.sourceDevice)") }
        parts.append(ByteCountFormatter.string(fromByteCount: Int64(backup.sizeBytes), countStyle: .file))
        return parts.joined(separator: " · ")
    }
}
