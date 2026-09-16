import SwiftUI

/// The Settings tab, grouped General / Reading / Requests / Privacy to
/// match the macOS settings window. iOS-only items (theme editor,
/// recovery key, wipe threshold, accounts, background checks) keep their
/// place inside the matching group.
struct SettingsView: View {
    @Environment(AppTheme.self) private var theme
    @Environment(AppState.self) private var state
    @Environment(NavigationState.self) private var nav

    @State private var chapterCleanupRan = false
    @State private var confirmRemoveCloudCopy = false
    @State private var linkMode: ExternalLinkOpener.Mode = .system

    private let timeouts = [15, 30, 60, 120]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 32) {
                // Header
                HStack {
                    Text("Settings")
                        .font(Typography.browseTitle())
                        .foregroundStyle(theme.ink)
                    Spacer()
                    PrivacyPillView {
                        nav.presentedSheet = .privacy
                    }
                }
                .padding(.horizontal, theme.pad)
                .padding(.top, 8)

                generalGroup
                readingGroup
                requestsGroup
                privacyGroup
                syncGroup

                // Footer
                VStack(spacing: 8) {
                    Text("Archive of Your Own")
                        .font(Typography.sheetTitle())
                        .foregroundStyle(theme.ink3)

                    Text("Nothing you read leaves this device.")
                        .font(Typography.uiSmall())
                        .foregroundStyle(theme.ink3)
                }
                .frame(maxWidth: .infinity)
                .padding(.top, 16)
                .padding(.bottom, 32)
            }
            .padding(.bottom, 16)
        }
        .background { ThemeBackgroundView() }
        .scrollDismissesKeyboard(.interactively)
        .onAppear { linkMode = ExternalLinkOpener.mode(state.bridge) }
    }

    // MARK: - General

    private var generalGroup: some View {
        settingsGroup(title: "General") {
            ToggleRowView(isOn: Binding(
                get: { state.hideExplicit },
                set: { state.hideExplicit = $0 }
            )) {
                settingsLabel(icon: "eye.slash", title: "Hide explicit works")
            }
            settingsCaption("Filters Explicit-rated works from lists and search results.")

            divider

            VStack(alignment: .leading, spacing: 8) {
                settingsLabel(icon: "safari", title: "Open links in")
                SegmentedControlView(
                    selection: Binding(
                        get: { linkMode },
                        set: { linkMode = $0; ExternalLinkOpener.setMode($0, state.bridge) }),
                    items: ExternalLinkOpener.Mode.allCases.map { (key: $0, label: $0.label) }
                )
                settingsCaption("Links that leave the app open this way. Anything opened this way travels over that browser's own connection, not this app's private one.")
            }
            .padding(.vertical, 4)

            divider

            navRow(icon: "paintpalette", title: "Appearance & Theme", detail: theme.activeTheme.name) {
                nav.presentedSheet = .themeEditor
            }

            divider

            navRow(icon: "person.2", title: "AO3 Accounts",
                   detail: state.ao3AccountCount > 0
                       ? "\(state.ao3AccountCount) account\(state.ao3AccountCount == 1 ? "" : "s")" : "None",
                   detailTint: state.ao3AccountCount > 0 ? theme.sage : theme.ink3) {
                nav.settingsPath.append(AppDestination.accountManagement)
            }

            divider

            Button {
                if state.sampleDataLoaded {
                    state.clearSampleData()
                } else {
                    state.loadSampleData()
                }
            } label: {
                HStack(spacing: 12) {
                    settingsLabel(icon: "testtube.2",
                                  title: state.sampleDataLoaded ? "Remove Sample Data" : "Load Sample Data")
                    Spacer()
                    Text(state.sampleDataLoaded ? "Loaded" : "Not loaded")
                        .font(Typography.uiSmall())
                        .foregroundStyle(state.sampleDataLoaded ? theme.sage : theme.ink3)
                }
                .padding(.vertical, 4)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            settingsCaption("Fictional works for testing and demos. Samples live in memory only — they never enter your encrypted library or touch the archive, and they disappear on quit.")
        }
    }

    // MARK: - Reading

    private var readingGroup: some View {
        settingsGroup(title: "Reading") {
            navRow(icon: "textformat.size", title: "Typography & theme", detail: nil) {
                nav.presentedSheet = .readingSettings
            }
            settingsCaption("Typeface, text size, spacing, layout, images.")

            divider

            VStack(alignment: .leading, spacing: 8) {
                settingsLabel(icon: "clock", title: "Reading history")
                Picker("History", selection: Binding(
                    get: { state.historyMode },
                    set: { state.historyMode = $0 }
                )) {
                    Text("Kept").tag(AppState.HistoryMode.persisted)
                    Text("Clear on close").tag(AppState.HistoryMode.clearOnClose)
                    Text("Off").tag(AppState.HistoryMode.disabled)
                }
                .pickerStyle(.segmented)
                settingsCaption(historyModeCaption)
            }
            .padding(.vertical, 4)

            divider

            ToggleRowView(isOn: Binding(
                get: { state.backgroundCheckEnabled },
                set: { state.backgroundCheckEnabled = $0 }
            )) {
                settingsLabel(icon: "bell.badge", title: "Check for new works in the background")
            }
            settingsCaption(state.backgroundCheckEnabled
                ? "iOS runs a check every few hours when it can. Each run starts a Tor connection, so this costs traffic even when nothing is new. You'll get a notification and an app badge when works update."
                : "Off: works are only checked when you ask (the ↻ on the Shelf). Turn on to be notified of updates while the app is closed; each check starts a Tor connection.")
        }
    }

    // MARK: - Requests

    private var requestsGroup: some View {
        settingsGroup(title: "Requests") {
            VStack(alignment: .leading, spacing: 8) {
                settingsLabel(icon: "timer", title: "Global timeout")
                SegmentedControlView(
                    selection: Binding(
                        get: { theme.requestTimeout },
                        set: {
                            theme.requestTimeout = $0
                            // Mirror into the core — theme only persists the
                            // preference; requests read the bridge's value.
                            state.bridge.setRequestTimeout(UInt64($0))
                        }),
                    items: timeouts.map { (key: $0, label: "\($0)s") }
                )
                settingsCaption("How long to wait for the archive to respond.")
            }
            .padding(.vertical, 4)

            divider

            navRow(icon: "list.bullet.rectangle", title: "Per-page timeouts", detail: nil) {
                nav.settingsPath.append(AppDestination.routeTimeouts)
            }

            divider

            navRow(icon: "clock.arrow.circlepath", title: "Log retention", detail: nil) {
                nav.settingsPath.append(AppDestination.logRetention)
            }

            divider

            navRow(icon: "network", title: "Request Log", detail: nil) {
                nav.settingsPath.append(AppDestination.requestLog)
            }

            divider

            navRow(icon: "ladybug", title: "Debug Log", detail: nil) {
                nav.settingsPath.append(AppDestination.debugLog)
            }
        }
    }

    // MARK: - Privacy

    private var privacyGroup: some View {
        settingsGroup(title: "Privacy") {
            ToggleRowView(isOn: Binding(
                get: { theme.useTorByDefault },
                set: { theme.useTorByDefault = $0 }
            )) {
                settingsLabel(icon: "shield.checkmark", title: "Connect via Tor on launch")
            }

            divider

            navRow(icon: "lock.shield", title: "Database password",
                   detail: state.bridge.hasDbPassword ? "Protected" : "Not set",
                   detailTint: state.bridge.hasDbPassword ? theme.sage : theme.ink3) {
                nav.presentedSheet = .databasePasswordReset
            }

            divider

            HStack(spacing: 12) {
                settingsLabel(icon: "exclamationmark.triangle", title: "Wipe after failed unlocks")
                Spacer()
                TextField("0", value: Binding(
                    get: { RecoveryKey.wipeThreshold },
                    set: { RecoveryKey.wipeThreshold = max(0, $0) }
                ), format: .number)
                .keyboardType(.numberPad)
                .multilineTextAlignment(.trailing)
                .font(.custom("HankenGrotesk", size: 15).weight(.semibold))
                .foregroundStyle(theme.ink)
                .frame(width: 40)
                Text(RecoveryKey.wipeThreshold == 0 ? "off" : "tries")
                    .font(Typography.uiSmall())
                    .foregroundStyle(theme.ink3)
            }
            .padding(.vertical, 4)

            divider

            HStack(spacing: 12) {
                settingsLabel(icon: "lock.rotation", title: "Lock after")
                Spacer()
                TextField("0", value: Binding(
                    get: { state.autoLockMinutes },
                    set: { state.autoLockMinutes = min(9999, max(0, $0)) }
                ), format: .number)
                .keyboardType(.numberPad)
                .multilineTextAlignment(.trailing)
                .font(.custom("HankenGrotesk", size: 15).weight(.semibold))
                .foregroundStyle(theme.ink)
                .frame(width: 50)
                Text("min")
                    .font(Typography.uiSmall())
                    .foregroundStyle(theme.ink3)
            }
            .padding(.vertical, 4)
            .disabled(!state.bridge.hasDbPassword)
            .opacity(state.bridge.hasDbPassword ? 1 : 0.5)

            ToggleRowView(isOn: Binding(
                get: { state.lockOnBackground },
                set: { state.lockOnBackground = $0 }
            )) {
                settingsLabel(icon: "lock.app.dashed", title: "Lock when leaving the app")
            }
            .disabled(!state.bridge.hasDbPassword)
            .opacity(state.bridge.hasDbPassword ? 1 : 0.5)
            settingsCaption(autoLockCaption)

            divider

            settingsRow(icon: "arrow.down.circle", title: "Offline downloads",
                        detail: "\(state.downloadedWorkIDs.count) works")

            ToggleRowView(isOn: Binding(
                get: { state.autoPurgeChapters },
                set: { state.autoPurgeChapters = $0 }
            )) {
                settingsLabel(icon: "arrow.3.trianglepath", title: "Clean up chapters automatically")
            }
            settingsCaption("Removes cached chapters of works that aren't downloaded or currently reading.")

            Button {
                state.purgeStaleChaptersNow()
                chapterCleanupRan = true
            } label: {
                HStack {
                    Text(chapterCleanupRan ? "Cleanup complete" : "Clean up chapters now")
                        .font(Typography.uiBody())
                        .foregroundStyle(chapterCleanupRan ? theme.sage : theme.ink)
                    Spacer()
                    Image(systemName: chapterCleanupRan ? "checkmark" : "trash")
                        .foregroundStyle(chapterCleanupRan ? theme.sage : theme.ink3)
                }
            }
            if chapterCleanupRan {
                settingsCaption("Downloaded and in-progress works keep their chapters.")
            }
        }
    }

    // MARK: - Settings Group

    private func settingsGroup<Content: View>(title: String, @ViewBuilder content: () -> Content) -> some View {
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

    private var divider: some View {
        Divider().foregroundStyle(theme.line)
    }

    // MARK: - iCloud Sync

    private var syncGroup: some View {
        let sync = state.cloudSync
        return settingsGroup(title: "iCloud Sync") {
            ToggleRowView(isOn: Binding(
                get: { sync.enabled },
                set: { sync.setEnabled($0) }
            )) {
                settingsLabel(icon: "icloud", title: "Keep a copy of this library in iCloud")
            }
            settingsCaption("The whole encrypted library, so another device can pick it up. One device at a time owns the iCloud copy and refreshes it while its library changes; opening the app elsewhere asks whether to use that copy there or replace it. Whatever gets replaced is kept as a backup. The key travels only through iCloud Keychain.")

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

            if let conflict = sync.pendingConflict {
                divider
                settingsCaption("iCloud holds \(conflict.deviceName)'s library, updated \(RelativeDateTimeFormatter().localizedString(for: conflict.writtenAt, relativeTo: Date())).")
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

    private var autoLockCaption: String {
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

    private var historyModeCaption: String {
        switch state.historyMode {
        case .persisted: "Reading history is kept in your encrypted library until you clear it."
        case .clearOnClose: "History is erased once the app has been closed or in the background for a few minutes."
        case .disabled: "No new reading history is recorded. Existing entries stay until cleared."
        }
    }

    private func settingsCaption(_ text: String) -> some View {
        Text(text)
            .font(Typography.uiCaption())
            .foregroundStyle(theme.ink3)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - Row Helpers

    private func settingsLabel(icon: String, title: String) -> some View {
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

    private func settingsRow(icon: String, title: String, detail: String) -> some View {
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
    private func navRow(icon: String, title: String, detail: String?, detailTint: Color? = nil,
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

#Preview {
    SettingsView()
        .environment(AppTheme())
        .environment(AppState())
        .environment(NavigationState())
}
