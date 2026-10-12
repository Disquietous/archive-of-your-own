import AppKit
import SwiftUI

// MARK: - Privacy

struct PrivacySettingsPane: View {
    @Bindable var theme: AppTheme
    let appState: AppState
    @Bindable var model: MacAppModel

    @State private var showPasswordSheet = false
    @State private var showRemoveConfirm = false
    @State private var chapterCleanupRan = false

    var body: some View {
        let _ = theme.uiFontScale  // track app text size so fonts refresh live
        VStack(alignment: .leading, spacing: 16) {
            SettingsGroup(theme: theme, label: "Protection") {
                SettingsCard(theme: theme) {
                    SettingsInfoRow(theme: theme, label: "Library password",
                                    value: appState.bridge.hasDbPassword ? "On" : "Off")
                }
                HStack(spacing: 8) {
                    ghostButton(appState.bridge.hasDbPassword ? "Change Password…" : "Set Password…",
                                tint: theme.ink) {
                        showPasswordSheet = true
                    }
                    if appState.bridge.hasDbPassword {
                        ghostButton("Remove Password", tint: Color(hex: "CE514D")) {
                            showRemoveConfirm = true
                        }
                    }
                }
            }
            .sheet(isPresented: $showPasswordSheet) {
                PasswordChangeSheet(theme: theme, appState: appState)
            }
            .alert("Remove Password?", isPresented: $showRemoveConfirm) {
                Button("Remove", role: .destructive) {
                    if appState.bridge.removePassword() {
                        RecoveryKey.deleteEncryptedBlob()
                    }
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("The library stays encrypted, but the key will be stored in the Keychain instead of requiring your password at launch.")
            }

            SettingsGroup(theme: theme, label: "Auto-Lock") {
                HStack(spacing: 8) {
                    Text("Lock when idle for")
                        .font(Font(MacFont.ui(13, weight: .medium)))
                        .foregroundStyle(theme.ink)
                    TextField("5", text: autoLockBinding)
                        .textFieldStyle(.plain)
                        .multilineTextAlignment(.center)
                        .font(Font(MacFont.ui(13, weight: .semibold)))
                        .foregroundStyle(theme.ink)
                        .frame(width: 52, height: 28)
                        .background(theme.surface)
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                        .overlay(RoundedRectangle(cornerRadius: 8).stroke(theme.line, lineWidth: 1))
                    Text("minutes")
                        .font(Font(MacFont.ui(13, weight: .medium)))
                        .foregroundStyle(theme.ink)
                    Spacer()
                }
                Text(autoLockCaption)
                    .font(Font(MacFont.ui(11.5)))
                    .foregroundStyle(theme.ink3)
                    .fixedSize(horizontal: false, vertical: true)
            }

            SettingsGroup(theme: theme, label: "Reading History") {
                HStack(spacing: 3) {
                    historyModeButton("Persisted", mode: .persisted)
                    historyModeButton("Clear on Quit", mode: .clearOnClose)
                    historyModeButton("Disabled", mode: .disabled)
                }
                .padding(3)
                .background(theme.surface2)
                .clipShape(RoundedRectangle(cornerRadius: 10))
                Text(historyModeCaption)
                    .font(Font(MacFont.ui(11.5)))
                    .foregroundStyle(theme.ink3)
                    .fixedSize(horizontal: false, vertical: true)
            }

            SettingsGroup(theme: theme, label: "Tor") {
                SettingsCard(theme: theme) {
                    SettingsToggleRow(theme: theme, label: "Connect via Tor on launch",
                                      sublabel: "Require a circuit before any network request",
                                      isOn: $theme.useTorByDefault)
                    theme.line.frame(height: 1)
                    SettingsInfoRow(theme: theme, label: "Status", value: appState.torStatus.displayText)
                }
                Button {
                    Task { await appState.connectTor() }
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "arrow.clockwise")
                            .font(.system(size: 12, weight: .semibold))
                        Text(appState.torStatus.isConnected ? "New circuit" : "Connect")
                            .font(Font(MacFont.ui(13.5, weight: .bold)))
                    }
                    .foregroundStyle(theme.ink)
                    .frame(maxWidth: .infinity, minHeight: 38)
                    .background(theme.surface)
                    .clipShape(RoundedRectangle(cornerRadius: 9))
                    .overlay(RoundedRectangle(cornerRadius: 9).stroke(theme.line, lineWidth: 1))
                }
                .buttonStyle(.plain)
            }

            SettingsGroup(theme: theme, label: "Storage") {
                SettingsCard(theme: theme) {
                    SettingsInfoRow(theme: theme, label: "Database", value: "Encrypted on device (SQLCipher)")
                    theme.line.frame(height: 1)
                    SettingsInfoRow(theme: theme, label: "Encryption key",
                                    value: appState.bridge.hasDbPassword ? "Your password" : "Stored in Keychain")
                    theme.line.frame(height: 1)
                    SettingsToggleRow(theme: theme, label: "Clean up chapters automatically",
                                      sublabel: "Remove cached chapters of works that aren't downloaded or currently reading",
                                      isOn: autoPurgeBinding)
                }
                ghostButton("Clean Up Chapters Now", tint: theme.ink) {
                    appState.purgeStaleChaptersNow()
                    chapterCleanupRan = true
                }
                if chapterCleanupRan {
                    Text("Cleanup complete. Downloaded and in-progress works keep their chapters.")
                        .font(Font(MacFont.ui(11.5)))
                        .foregroundStyle(theme.ink3)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .padding(16)
    }

    private var autoPurgeBinding: Binding<Bool> {
        Binding(get: { appState.autoPurgeChapters },
                set: { appState.autoPurgeChapters = $0 })
    }

    private var autoLockBinding: Binding<String> {
        Binding(get: { String(appState.autoLockMinutes) },
                set: { appState.autoLockMinutes = min(9999, max(0, Int($0.filter(\.isNumber)) ?? 0)) })
    }

    private var autoLockCaption: String {
        if !appState.bridge.hasDbPassword {
            return "Auto-lock requires a library password — set one above to enable it."
        }
        if appState.autoLockMinutes == 0 {
            return "Auto-lock is disabled. Enter a number of minutes to lock the library after inactivity."
        }
        return """
            After \(appState.autoLockMinutes) idle minute\(appState.autoLockMinutes == 1 ? "" : "s"), the library \
            locks and the app returns to the unlock screen. Any activity in the app resets the timer. 0 disables.
            """
    }

    private var historyModeCaption: String {
        switch appState.historyMode {
        case .persisted: "Reading history is kept in your encrypted library until you clear it."
        case .clearOnClose: "History is erased automatically every time the app quits."
        case .disabled: "No new reading history is recorded. Existing entries stay until cleared."
        }
    }

    private func historyModeButton(_ label: String, mode: AppState.HistoryMode) -> some View {
        let on = appState.historyMode == mode
        return Button {
            appState.historyMode = mode
        } label: {
            Text(label)
                .font(Font(MacFont.ui(12.5, weight: .semibold)))
                .foregroundStyle(on ? theme.ink : theme.ink3)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 7)
                .background(on ? theme.surface : .clear)
                .clipShape(RoundedRectangle(cornerRadius: 7))
        }
        .buttonStyle(.plain)
    }

    private func ghostButton(_ label: String, tint: Color, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(label)
                .font(Font(MacFont.ui(13, weight: .bold)))
                .foregroundStyle(tint)
                .frame(maxWidth: .infinity, minHeight: 34)
                .background(theme.surface)
                .clipShape(RoundedRectangle(cornerRadius: 9))
                .overlay(RoundedRectangle(cornerRadius: 9).stroke(theme.line, lineWidth: 1))
        }
        .buttonStyle(.plain)
    }
}

/// Set or change the library password from Settings. Rekeys the open database
/// and issues a fresh recovery key.
struct PasswordChangeSheet: View {
    @Bindable var theme: AppTheme
    let appState: AppState
    @Environment(\.dismiss) private var dismiss

    @State private var password = ""
    @State private var confirmPassword = ""
    @State private var error: String?
    @State private var recoveryKey: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(appState.bridge.hasDbPassword ? "Change Password" : "Set Password")
                .font(Font(MacFont.ui(15, weight: .bold)))
                .foregroundStyle(theme.ink)

            if let key = recoveryKey {
                VStack(spacing: 8) {
                    Text("RECOVERY KEY")
                        .font(Font(MacFont.ui(11, weight: .bold)))
                        .kerning(0.9)
                        .foregroundStyle(theme.ink3)
                    Text(key)
                        .font(.system(size: 16, design: .monospaced).weight(.bold))
                        .foregroundStyle(theme.ink)
                        .textSelection(.enabled)
                    Text("""
                        Write this down and keep it safe. If you forget your password, this is the only way to recover \
                        your data. It will not be shown again.
                        """)
                        .font(Font(MacFont.ui(12, weight: .medium)))
                        .foregroundStyle(Color(hex: "CE514D"))
                        .fixedSize(horizontal: false, vertical: true)
                    GateButton(theme: theme, label: "I've saved my recovery key", fill: theme.accent) {
                        dismiss()
                    }
                }
            } else {
                SecureField("New password", text: $password)
                    .textFieldStyle(.roundedBorder)
                SecureField("Confirm password", text: $confirmPassword)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { save() }
                if let error {
                    Text(error)
                        .font(Font(MacFont.ui(12, weight: .medium)))
                        .foregroundStyle(Color(hex: "CE514D"))
                }
                HStack {
                    Button("Cancel") { dismiss() }
                        .keyboardShortcut(.cancelAction)
                    Spacer()
                    Button("Save") { save() }
                        .keyboardShortcut(.defaultAction)
                }
            }
        }
        .padding(20)
        .frame(width: 340)
        .background(theme.surface)
    }

    private func save() {
        error = nil
        guard !password.isEmpty else { error = "Password cannot be empty."; return }
        guard password == confirmPassword else { error = "Passwords don't match."; return }
        guard password.count >= 4 else { error = "Password must be at least 4 characters."; return }
        guard appState.bridge.changePassword(to: password) else {
            error = "Failed to update the password."
            return
        }
        let key = RecoveryKey.generate()
        if let blob = RecoveryKey.encryptPassword(password, withRecoveryKey: key) {
            RecoveryKey.storeEncryptedBlob(blob)
            recoveryKey = key
        }
        RecoveryKey.resetFailureCount()
    }
}
