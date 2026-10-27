import SwiftUI

extension SettingsView {
    // MARK: - Settings Group

    func settingsGroup<Content: View>(title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title.uppercased())
                .font(Typography.sectionHeader())
                .tracking(0.08 * 13)
                .foregroundStyle(theme.ink3)
                .padding(.horizontal, theme.pad)

            VStack(alignment: .leading, spacing: 12) {
                content()
            }
            .padding(.horizontal, theme.cardPad)
            .padding(.vertical, theme.cardPad + 4)
            .background(
                RoundedRectangle(cornerRadius: Radius.settingsGroup)
                    .fill(theme.surface)
            )
            .padding(.horizontal, theme.pad)
        }
    }

    var divider: some View {
        Divider().foregroundStyle(theme.line)
    }

    // MARK: - iCloud Sync

    var syncGroup: some View {
        let sync = state.cloudSync
        return settingsGroup(title: "iCloud Sync") {
            ToggleRowView(isOn: Binding(
                get: { sync.enabled },
                set: { sync.setEnabled($0) }
            )) {
                settingsLabel(icon: "icloud", title: "Keep a copy of this library in iCloud")
            }
            settingsCaption("""
                The whole encrypted library, so another device can pick it up. One device at a time owns the iCloud \
                copy and refreshes it while its library changes; opening the app elsewhere asks whether to use that \
                copy there or replace it. Whatever gets replaced is kept as a backup. The key travels only through \
                iCloud Keychain.
                """)

            divider

            HStack(spacing: 12) {
                settingsLabel(icon: "arrow.triangle.2.circlepath", title: "Status")
                Spacer()
                Text(sync.status.displayText)
                    .font(Typography.uiSmall())
                    .foregroundStyle(sync.status == .idle ? theme.sage : theme.ink3)
                    .multilineTextAlignment(.trailing)
            }
            .padding(.vertical, 4)

            if let at = sync.lastPushedAt {
                settingsCaption("Last sent to iCloud \(RelativeDateTimeFormatter().localizedString(for: at, relativeTo: Date())).")
            }
            if let at = sync.lastCheckedAt {
                settingsCaption("Last checked \(RelativeDateTimeFormatter().localizedString(for: at, relativeTo: Date())).")
            }

            if let conflict = sync.pendingConflict {
                divider
                settingsCaption("""
                    iCloud holds \(conflict.deviceName)'s library, updated \
                    \(RelativeDateTimeFormatter().localizedString(for: conflict.writtenAt, relativeTo: Date())).
                    """)
                Button { sync.resolve(.useCloudCopy) } label: {
                    HStack(spacing: 12) {
                        settingsLabel(icon: "icloud.and.arrow.down", title: "Use iCloud Copy Here")
                        Spacer()
                    }
                    .padding(.vertical, 4)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(sync.busy)
                Button { sync.resolve(.overwriteCloudCopy) } label: {
                    HStack(spacing: 12) {
                        settingsLabel(icon: "icloud.and.arrow.up", title: "Replace iCloud Copy With This Library")
                        Spacer()
                    }
                    .padding(.vertical, 4)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(sync.busy)
                Button { sync.resolve(.notNow) } label: {
                    HStack(spacing: 12) {
                        settingsLabel(icon: "xmark.circle", title: "Not Now")
                        Spacer()
                    }
                    .padding(.vertical, 4)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }

            divider

            Button {
                sync.syncNow()
            } label: {
                HStack(spacing: 12) {
                    settingsLabel(icon: "arrow.clockwise.icloud", title: "Sync Now")
                    Spacer()
                }
                .padding(.vertical, 4)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(!sync.enabled || sync.busy)
            .opacity(sync.enabled ? 1 : 0.5)

            divider

            Button {
                nav.settingsPath.append(AppDestination.libraryBackups)
            } label: {
                HStack(spacing: 12) {
                    settingsLabel(icon: "clock.arrow.circlepath", title: "Backups")
                    Spacer()
                    Text(sync.backups.isEmpty ? "None" : "\(sync.backups.count)")
                        .font(Typography.uiSmall())
                        .foregroundStyle(theme.ink3)
                    Image(systemName: "chevron.right")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(theme.ink3)
                }
                .padding(.vertical, 4)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            divider

            Button {
                confirmRemoveCloudCopy = true
            } label: {
                HStack(spacing: 12) {
                    settingsLabel(icon: "icloud.slash", title: "Remove the iCloud Copy")
                    Spacer()
                }
                .padding(.vertical, 4)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(sync.busy)
            .confirmationDialog("Remove the library copy from iCloud?",
                                isPresented: $confirmRemoveCloudCopy, titleVisibility: .visible) {
                Button("Remove", role: .destructive) { sync.removeFromCloud() }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("Sync turns off on this device and the copy leaves iCloud. Every device keeps the library it has.")
            }
        }
    }

    // MARK: - Captions

    var autoLockCaption: String {
        if !state.bridge.hasDbPassword {
            return "Auto-lock needs a database password — set one above to enable it."
        }
        var parts: [String] = []
        if state.autoLockMinutes == 0 {
            parts.append("Timed lock is off; 0 means never.")
        } else {
            let m = state.autoLockMinutes
            parts.append("The library locks when the app has been in the background for \(m) minute\(m == 1 ? "" : "s").")
        }
        if state.lockOnBackground {
            parts.append("Leaving the app locks it immediately.")
        }
        return parts.joined(separator: " ")
    }

    var historyModeCaption: String {
        switch state.historyMode {
        case .persisted: "Reading history is kept in your encrypted library until you clear it."
        case .clearOnClose: "History is erased once the app has been closed or in the background for a few minutes."
        case .disabled: "No new reading history is recorded. Existing entries stay until cleared."
        }
    }

    func settingsCaption(_ text: String) -> some View {
        Text(text)
            .font(Typography.uiCaption())
            .foregroundStyle(theme.ink3)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - Row Helpers

    func settingsLabel(icon: String, title: String) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 16, weight: .medium))
                .foregroundStyle(theme.ink2)
                .frame(width: 28)

            Text(title)
                .font(Typography.uiBody())
                .foregroundStyle(theme.ink)
        }
    }

    func settingsRow(icon: String, title: String, detail: String) -> some View {
        HStack(spacing: 12) {
            settingsLabel(icon: icon, title: title)
            Spacer()
            Text(detail)
                .font(Typography.uiSmall())
                .foregroundStyle(theme.ink3)
        }
        .padding(.vertical, 4)
    }

    /// A row that pushes or presents something: label, optional detail,
    /// chevron.
    func navRow(icon: String, title: String, detail: String?, detailTint: Color? = nil,
                action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 12) {
                settingsLabel(icon: icon, title: title)
                Spacer()
                if let detail {
                    Text(detail)
                        .font(Typography.uiSmall())
                        .foregroundStyle(detailTint ?? theme.ink3)
                }
                Image(systemName: "chevron.right")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(theme.ink3)
            }
            .padding(.vertical, 4)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
