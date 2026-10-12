import SwiftUI

extension SettingsView {
    // MARK: - General

    var generalGroup: some View {
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
                settingsCaption("""
                    Links that leave the app open this way. Anything opened this way travels over that browser's own \
                    connection, not this app's private one.
                    """)
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

        }
    }

    // MARK: - Reading

    var readingGroup: some View {
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
        }
    }

    // MARK: - Requests

    var requestsGroup: some View {
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

    var privacyGroup: some View {
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

            if state.bridge.hasDbPassword, let biometryName = BiometricUnlock.biometryName {
                divider

                ToggleRowView(isOn: Binding(
                    get: { biometricEnabled },
                    set: { on in
                        if on {
                            biometricPasswordPrompt = true
                        } else {
                            BiometricUnlock.disable()
                            biometricEnabled = false
                        }
                    }
                )) {
                    settingsLabel(icon: biometryName == "Touch ID" ? "touchid" : "faceid",
                                  title: "Unlock with \(biometryName)")
                }
                settingsCaption(biometricEnabled
                    ? "On for this device. Your password is still needed after a restart or a wrong attempt."
                    : "Off. Turn on to unlock with \(biometryName) instead of typing your password.")
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
}
