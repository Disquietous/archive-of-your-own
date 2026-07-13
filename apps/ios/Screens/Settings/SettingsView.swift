import SwiftUI

struct SettingsView: View {
    @Environment(AppTheme.self) private var theme
    @Environment(AppState.self) private var state
    @Environment(NavigationState.self) private var nav

    @State private var newCircuitOnLaunch: Bool = true
    @State private var debugLogCopied = false

    private var hideExplicitBinding: Binding<Bool> {
        Binding(
            get: { state.hideExplicit },
            set: { state.hideExplicit = $0 }
        )
    }

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

                // Privacy group
                settingsGroup(title: "Privacy") {
                    // Hide explicit toggle
                    ToggleRowView(isOn: hideExplicitBinding) {
                        settingsLabel(
                            icon: "eye.slash",
                            title: "Hide explicit works"
                        )
                    }

                    Divider()
                        .foregroundStyle(theme.line)

                    // New circuit on launch toggle
                    ToggleRowView(isOn: $newCircuitOnLaunch) {
                        settingsLabel(
                            icon: "arrow.triangle.2.circlepath",
                            title: "New circuit on launch"
                        )
                    }

                    Divider()
                        .foregroundStyle(theme.line)

                    ToggleRowView(isOn: Binding(
                        get: { theme.useTorByDefault },
                        set: { theme.useTorByDefault = $0 }
                    )) {
                        settingsLabel(
                            icon: "shield.checkmark",
                            title: "Connect via Tor on launch"
                        )
                    }
                }

                // Library group
                settingsGroup(title: "Library") {
                    settingsRow(
                        icon: "arrow.down.circle",
                        title: "Offline downloads",
                        detail: "\(state.downloadedWorkIDs.count) works"
                    )

                    Divider()
                        .foregroundStyle(theme.line)

                    Button {
                        nav.presentedSheet = .databasePasswordReset
                    } label: {
                        HStack(spacing: 12) {
                            Image(systemName: "lock.shield")
                                .font(.system(size: 16, weight: .medium))
                                .foregroundStyle(theme.ink2)
                                .frame(width: 28)

                            Text("Database password")
                                .font(Typography.uiBody())
                                .foregroundStyle(theme.ink)

                            Spacer()

                            Text(state.bridge.hasDbPassword ? "Protected" : "Not set")
                                .font(Typography.uiSmall())
                                .foregroundStyle(state.bridge.hasDbPassword ? theme.sage : theme.ink3)

                            Image(systemName: "chevron.right")
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundStyle(theme.ink3)
                        }
                        .padding(.vertical, 4)
                    }
                    .buttonStyle(.plain)

                    Divider()
                        .foregroundStyle(theme.line)

                    HStack(spacing: 12) {
                        Image(systemName: "exclamationmark.triangle")
                            .font(.system(size: 16, weight: .medium))
                            .foregroundStyle(theme.ink2)
                            .frame(width: 28)

                        Text("Wipe after failed unlocks")
                            .font(Typography.uiBody())
                            .foregroundStyle(theme.ink)

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

                    Divider()
                        .foregroundStyle(theme.line)

                    Button {
                        nav.settingsPath.append(AppDestination.accountManagement)
                    } label: {
                        HStack(spacing: 12) {
                            Image(systemName: "person.2")
                                .font(.system(size: 16, weight: .medium))
                                .foregroundStyle(theme.ink2)
                                .frame(width: 28)

                            Text("AO3 Accounts")
                                .font(Typography.uiBody())
                                .foregroundStyle(theme.ink)

                            Spacer()

                            let count = state.ao3AccountCount
                            Text(count > 0 ? "\(count) account\(count == 1 ? "" : "s")" : "None")
                                .font(Typography.uiSmall())
                                .foregroundStyle(count > 0 ? theme.sage : theme.ink3)

                            Image(systemName: "chevron.right")
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundStyle(theme.ink3)
                        }
                        .padding(.vertical, 4)
                    }
                    .buttonStyle(.plain)
                }

                // Appearance group
                settingsGroup(title: "Appearance") {
                    Button {
                        nav.presentedSheet = .themeEditor
                    } label: {
                        HStack(spacing: 12) {
                            Image(systemName: "paintpalette")
                                .font(.system(size: 16, weight: .medium))
                                .foregroundStyle(theme.ink2)
                                .frame(width: 28)

                            Text("Appearance & Theme")
                                .font(Typography.uiBody())
                                .foregroundStyle(theme.ink)

                            Spacer()

                            Text(theme.activeTheme.name)
                                .font(Typography.uiSmall())
                                .foregroundStyle(theme.ink3)

                            Image(systemName: "chevron.right")
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundStyle(theme.ink3)
                        }
                        .padding(.vertical, 4)
                    }
                    .buttonStyle(.plain)
                }

                // Reading group
                settingsGroup(title: "Reading") {
                    Button {
                        nav.presentedSheet = .readingSettings
                    } label: {
                        HStack(spacing: 12) {
                            Image(systemName: "textformat.size")
                                .font(.system(size: 16, weight: .medium))
                                .foregroundStyle(theme.ink2)
                                .frame(width: 28)

                            Text("Typography & theme")
                                .font(Typography.uiBody())
                                .foregroundStyle(theme.ink)

                            Spacer()

                            Image(systemName: "chevron.right")
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundStyle(theme.ink3)
                        }
                        .padding(.vertical, 4)
                    }
                    .buttonStyle(.plain)
                }

                // Network group
                settingsGroup(title: "Network") {
                    HStack(spacing: 12) {
                        Image(systemName: "clock")
                            .font(.system(size: 16, weight: .medium))
                            .foregroundStyle(theme.ink2)
                            .frame(width: 28)

                        Text("Request timeout")
                            .font(Typography.uiBody())
                            .foregroundStyle(theme.ink)

                        Spacer()

                        TextField("30", value: Binding(
                            get: { theme.requestTimeout },
                            set: {
                                let clamped = max(5, $0)
                                theme.requestTimeout = clamped
                                state.bridge.setRequestTimeout(UInt64(clamped))
                            }
                        ), format: .number)
                        .keyboardType(.numberPad)
                        .multilineTextAlignment(.trailing)
                        .font(.custom("HankenGrotesk", size: 15).weight(.semibold))
                        .foregroundStyle(theme.ink)
                        .frame(width: 50)

                        Text("sec")
                            .font(Typography.uiSmall())
                            .foregroundStyle(theme.ink3)
                    }
                    .padding(.vertical, 4)
                }

                // Debug
                settingsGroup(title: "Debug") {
                    Button {
                        let logs = state.bridge.dumpLogs(limit: 1000)
                        UIPasteboard.general.string = logs
                        debugLogCopied = true
                        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                            debugLogCopied = false
                        }
                    } label: {
                        HStack {
                            Text(debugLogCopied ? "Copied to clipboard!" : "Copy debug logs")
                                .font(Typography.uiBody())
                                .foregroundStyle(debugLogCopied ? theme.sage : theme.ink)
                            Spacer()
                            Image(systemName: debugLogCopied ? "checkmark" : "doc.on.clipboard")
                                .foregroundStyle(debugLogCopied ? theme.sage : theme.ink3)
                        }
                    }

                    Button {
                        state.bridge.clearLogs()
                    } label: {
                        HStack {
                            Text("Clear debug logs")
                                .font(Typography.uiBody())
                                .foregroundStyle(theme.ink)
                            Spacer()
                            Image(systemName: "trash")
                                .foregroundStyle(theme.ink3)
                        }
                    }
                }

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
    }

    // MARK: - Settings Group

    private func settingsGroup<Content: View>(title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title.uppercased())
                .font(Typography.sectionHeader())
                .tracking(0.08 * 13)
                .foregroundStyle(theme.ink3)
                .padding(.horizontal, theme.pad)

            VStack(spacing: 12) {
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
            Image(systemName: icon)
                .font(.system(size: 16, weight: .medium))
                .foregroundStyle(theme.ink2)
                .frame(width: 28)

            Text(title)
                .font(Typography.uiBody())
                .foregroundStyle(theme.ink)

            Spacer()

            Text(detail)
                .font(Typography.uiSmall())
                .foregroundStyle(theme.ink3)
        }
        .padding(.vertical, 4)
    }
}

#Preview {
    SettingsView()
        .environment(AppTheme())
        .environment(AppState())
        .environment(NavigationState())
}
