import SwiftUI

/// Settings › Sync: the iCloud library switch and status, the pending
/// decision when another device wrote the iCloud copy, the backups the
/// core filed away, and the removal action.
struct CloudSyncSettingsPane: View {
    @Bindable var theme: AppTheme
    @Bindable var appState: AppState

    @State private var confirmRemove = false
    @State private var restoreCandidate: CloudLibrarySync.Backup?
    @State private var deleteCandidate: CloudLibrarySync.Backup?

    private var sync: CloudLibrarySync { appState.cloudSync }

    var body: some View {
        let _ = theme.uiFontScale  // track app text size so fonts refresh live
        VStack(alignment: .leading, spacing: 16) {
            SettingsGroup(theme: theme, label: "iCloud") {
                SettingsCard(theme: theme) {
                    SettingsToggleRow(theme: theme, label: "Keep a copy of this library in iCloud",
                                      sublabel: "The whole encrypted library, so another device can pick it up",
                                      isOn: Binding(get: { sync.enabled }, set: { sync.setEnabled($0) }))
                    Divider().foregroundStyle(theme.line)
                    SettingsInfoRow(theme: theme, label: "Status", value: sync.status.displayText)
                    Divider().foregroundStyle(theme.line)
                    SettingsInfoRow(theme: theme, label: "Last sent to iCloud",
                                    value: sync.lastPushedAt.map(Self.relative) ?? "Never")
                    Divider().foregroundStyle(theme.line)
                    SettingsInfoRow(theme: theme, label: "This device", value: sync.deviceName)
                }
                if let conflict = sync.pendingConflict {
                    conflictCard(conflict)
                }
                actionButton("Sync Now", enabled: sync.enabled && !sync.busy) { sync.syncNow() }
                Text("One device at a time owns the iCloud copy and refreshes it every few minutes while its library changes, and again when the app closes. When you open the app on another device, it notices the copy came from elsewhere and asks whether to use that copy here or replace it with this device's library. Whichever library is replaced is kept as a backup below. The copy is encrypted with a key that travels only through iCloud Keychain.")
                    .font(Font(MacFont.ui(11.5)))
                    .foregroundStyle(theme.ink3)
                    .fixedSize(horizontal: false, vertical: true)
            }

            SettingsGroup(theme: theme, label: "Backups") {
                SettingsCard(theme: theme) {
                    if sync.backups.isEmpty {
                        Text("No backups yet. One is made whenever this library is replaced — by the iCloud copy, or by restoring a backup — and whenever this device replaces another device's iCloud copy.")
                            .font(Font(MacFont.ui(12.5)))
                            .foregroundStyle(theme.ink3)
                            .padding(.vertical, 9)
                    } else {
                        ForEach(Array(sync.backups.enumerated()), id: \.element.id) { index, backup in
                            if index > 0 { Divider().foregroundStyle(theme.line) }
                            backupRow(backup)
                        }
                    }
                }
                Text("Restoring a backup replaces this device's library with it; the library being replaced becomes a new backup first.")
                    .font(Font(MacFont.ui(11.5)))
                    .foregroundStyle(theme.ink3)
                    .fixedSize(horizontal: false, vertical: true)
            }

            SettingsGroup(theme: theme, label: "Remove") {
                actionButton("Remove the iCloud Copy", tint: Color(hex: "CE514D"), enabled: !sync.busy) {
                    confirmRemove = true
                }
                .confirmationDialog("Remove the library copy from iCloud?",
                                    isPresented: $confirmRemove, titleVisibility: .visible) {
                    Button("Remove", role: .destructive) { sync.removeFromCloud() }
                    Button("Cancel", role: .cancel) {}
                } message: {
                    Text("Sync turns off on this Mac and the copy leaves iCloud. Every device keeps the library it has.")
                }
            }
        }
        .padding(16)
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
                Text("This Mac's library will be replaced with the backup from \(Self.absolute(b.createdAt)). The current library is kept as a new backup.")
            }
        }
        .confirmationDialog("Remove this backup?", isPresented: Binding(
            get: { deleteCandidate != nil }, set: { if !$0 { deleteCandidate = nil } }
        ), titleVisibility: .visible) {
            Button("Remove", role: .destructive) {
                if let b = deleteCandidate { sync.deleteBackup(id: b.id) }
                deleteCandidate = nil
            }
            Button("Cancel", role: .cancel) { deleteCandidate = nil }
        } message: {
            Text("The backup file is deleted. This can't be undone.")
        }
    }

    private func conflictCard(_ conflict: CloudLibrarySync.Conflict) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("iCloud holds \(conflict.deviceName)'s library, updated \(Self.relative(conflict.writtenAt)).")
                .font(Font(MacFont.ui(13, weight: .medium)))
                .foregroundStyle(theme.ink)
                .fixedSize(horizontal: false, vertical: true)
            Text("Use it here (this Mac's library becomes a backup), or replace it with this Mac's library (the iCloud copy becomes a backup).")
                .font(Font(MacFont.ui(11.5)))
                .foregroundStyle(theme.ink3)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 8) {
                actionButton("Use iCloud Copy", enabled: !sync.busy) { sync.resolve(.useCloudCopy) }
                actionButton("Replace iCloud Copy", enabled: !sync.busy) { sync.resolve(.overwriteCloudCopy) }
                actionButton("Not Now", enabled: true) { sync.resolve(.notNow) }
            }
        }
        .padding(13)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(theme.surface)
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(theme.sage, lineWidth: 1.5))
    }

    private func backupRow(_ backup: CloudLibrarySync.Backup) -> some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 1) {
                Text(Self.absolute(backup.createdAt))
                    .font(Font(MacFont.ui(13.5, weight: .medium)))
                    .foregroundStyle(theme.ink)
                Text(Self.subtitle(for: backup))
                    .font(Font(MacFont.ui(11.5)))
                    .foregroundStyle(theme.ink3)
            }
            Spacer()
            Button("Restore") { restoreCandidate = backup }
                .font(Font(MacFont.ui(12)))
                .disabled(sync.busy)
            Button("Remove") { deleteCandidate = backup }
                .font(Font(MacFont.ui(12)))
                .disabled(sync.busy)
        }
        .padding(.vertical, 9)
    }

    private func actionButton(_ title: String, tint: Color? = nil, enabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(Font(MacFont.ui(13, weight: .bold)))
                .foregroundStyle(enabled ? (tint ?? theme.ink) : theme.ink3)
                .frame(maxWidth: .infinity, minHeight: 34)
                .background(theme.surface)
                .clipShape(RoundedRectangle(cornerRadius: 9))
                .overlay(RoundedRectangle(cornerRadius: 9).stroke(theme.line, lineWidth: 1))
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
    }

    static func subtitle(for backup: CloudLibrarySync.Backup) -> String {
        var parts: [String] = []
        if !backup.reason.isEmpty { parts.append(backup.reason) }
        if !backup.sourceDevice.isEmpty { parts.append("from \(backup.sourceDevice)") }
        parts.append(ByteCountFormatter.string(fromByteCount: Int64(backup.sizeBytes), countStyle: .file))
        return parts.joined(separator: " · ")
    }

    private static func relative(_ date: Date) -> String {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .abbreviated
        return f.localizedString(for: date, relativeTo: Date())
    }

    private static func absolute(_ date: Date) -> String {
        date.formatted(date: .abbreviated, time: .shortened)
    }
}
