import SwiftUI

/// Pre-main-UI gate, mirroring the iOS launch flow: database setup on first
/// launch (password / skip / later + recovery key) and the unlock screen for
/// password-protected libraries. Shown as the window's content until the
/// database is open.
struct LaunchGateView: View {
    @Bindable var theme: AppTheme
    let appState: AppState

    var body: some View {
        Group {
            switch appState.bridge.launchState {
            case .firstLaunch:
                MacDatabaseSetupView(theme: theme, appState: appState)
            case .locked:
                MacDatabaseUnlockView(theme: theme, appState: appState)
            case .autoUnlock:
                theme.bg.onAppear { _ = appState.bridge.open() }
            case .connectingTor, .ready:
                // Unlocked — the window is about to swap to the main UI;
                // render only the background so nothing flashes.
                theme.bg
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(theme.bg)
    }
}

// MARK: - First launch: Protect Your Library

struct MacDatabaseSetupView: View {
    @Bindable var theme: AppTheme
    let appState: AppState

    @State private var password = ""
    @State private var confirmPassword = ""
    @State private var error: String?
    @State private var generatedRecoveryKey: String?
    @State private var useTor = UserDefaults.standard.bool(forKey: "useTorByDefault")

    var body: some View {
        VStack(spacing: 0) {
            Image(systemName: "lock.shield")
                .font(.system(size: 44, weight: .medium))
                .foregroundStyle(theme.sage)
                .padding(.bottom, 16)
            Text("Protect Your Library")
                .font(Font(MacFont.serif(32, weight: .semibold)))
                .foregroundStyle(theme.ink)
                .padding(.bottom, 6)
            Text("Your reading history and bookmarks are stored\nin an encrypted database on this device.")
                .font(Font(MacFont.ui(14, weight: .medium)))
                .foregroundStyle(theme.ink3)
                .multilineTextAlignment(.center)
                .padding(.bottom, 28)

            VStack(spacing: 14) {
                gateField { SecureField("Password", text: $password) }
                gateField { SecureField("Confirm password", text: $confirmPassword).onSubmit { setPassword() } }

                if let error {
                    Text(error)
                        .font(Font(MacFont.ui(12, weight: .medium)))
                        .foregroundStyle(Color(hex: "CE514D"))
                }

                if let key = generatedRecoveryKey {
                    recoveryKeyBlock(key)
                } else {
                    GateButton(theme: theme, label: "Set Password", fill: theme.sage) { setPassword() }
                }
            }
            .frame(width: 340)

            Toggle(isOn: $useTor) {
                HStack(spacing: 8) {
                    Image(systemName: "shield.checkmark")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(useTor ? theme.sage : theme.ink3)
                    Text("Connect via Tor on launch")
                        .font(Font(MacFont.ui(13.5, weight: .medium)))
                        .foregroundStyle(theme.ink)
                }
            }
            .toggleStyle(.switch)
            .tint(theme.sage)
            .padding(.top, 18)
            .onChange(of: useTor) { _, newValue in
                UserDefaults.standard.set(newValue, forKey: "useTorByDefault")
            }

            if generatedRecoveryKey == nil {
                VStack(spacing: 10) {
                    Button("Skip — no password") {
                        RustBridge.promptForPassword = false
                        _ = appState.bridge.createWithAutoKey()
                    }
                    Button("Ask me later") {
                        _ = appState.bridge.createWithAutoKey()
                    }
                }
                .buttonStyle(.plain)
                .font(Font(MacFont.ui(12.5, weight: .semibold)))
                .foregroundStyle(theme.ink3)
                .padding(.top, 24)
            }
        }
        .padding(40)
    }

    private func gateField(@ViewBuilder content: () -> some View) -> some View {
        content()
            .textFieldStyle(.plain)
            .font(Font(MacFont.ui(15, weight: .medium)))
            .padding(.horizontal, 16)
            .frame(height: 44)
            .background(theme.surface)
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(theme.line, lineWidth: 1))
    }

    private func recoveryKeyBlock(_ key: String) -> some View {
        VStack(spacing: 8) {
            Text("RECOVERY KEY")
                .font(Font(MacFont.ui(11, weight: .bold)))
                .kerning(0.9)
                .foregroundStyle(theme.ink3)
            Text(key)
                .font(.system(size: 18, design: .monospaced).weight(.bold))
                .foregroundStyle(theme.ink)
                .multilineTextAlignment(.center)
                .textSelection(.enabled)
            Text("Write this down and keep it safe. If you forget your password, this is the only way to recover your data. It will not be shown again.")
                .font(Font(MacFont.ui(12, weight: .medium)))
                .foregroundStyle(Color(hex: "CE514D"))
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            GateButton(theme: theme, label: "I've saved my recovery key", fill: theme.accent) {
                appState.bridge.showingRecoveryKey = false
            }
            .padding(.top, 8)
        }
    }

    private func setPassword() {
        error = nil
        guard !password.isEmpty else { error = "Password cannot be empty."; return }
        guard password == confirmPassword else { error = "Passwords don't match."; return }
        guard password.count >= 4 else { error = "Password must be at least 4 characters."; return }

        if !appState.bridge.createWithPassword(password) {
            error = "Failed to create database."
            return
        }
        let key = RecoveryKey.generate()
        if let blob = RecoveryKey.encryptPassword(password, withRecoveryKey: key) {
            RecoveryKey.storeEncryptedBlob(blob)
            generatedRecoveryKey = key
            appState.bridge.showingRecoveryKey = true
        }
        RecoveryKey.resetFailureCount()
    }
}

// MARK: - Locked: Enter Password

struct MacDatabaseUnlockView: View {
    @Bindable var theme: AppTheme
    let appState: AppState

    @State private var password = ""
    @State private var error: String?
    @State private var showRecovery = false
    @State private var recoveryKeyInput = ""
    @State private var showWipeConfirm = false

    var body: some View {
        VStack(spacing: 0) {
            Image(systemName: "lock.fill")
                .font(.system(size: 44, weight: .medium))
                .foregroundStyle(theme.accent)
                .padding(.bottom, 16)
            Text("Enter Password")
                .font(Font(MacFont.serif(32, weight: .semibold)))
                .foregroundStyle(theme.ink)
                .padding(.bottom, 6)
            Text("Your library is encrypted.\nEnter your password to unlock it.")
                .font(Font(MacFont.ui(14, weight: .medium)))
                .foregroundStyle(theme.ink3)
                .multilineTextAlignment(.center)
                .padding(.bottom, 28)

            VStack(spacing: 14) {
                if !showRecovery {
                    SecureField("Password", text: $password)
                        .textFieldStyle(.plain)
                        .font(Font(MacFont.ui(15, weight: .medium)))
                        .padding(.horizontal, 16)
                        .frame(height: 44)
                        .background(theme.surface)
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                        .overlay(RoundedRectangle(cornerRadius: 12).stroke(theme.line, lineWidth: 1))
                        .onSubmit { unlock() }

                    if let error {
                        Text(error)
                            .font(Font(MacFont.ui(12, weight: .medium)))
                            .foregroundStyle(Color(hex: "CE514D"))
                    }

                    GateButton(theme: theme, label: "Unlock", fill: theme.accent) { unlock() }

                    if RecoveryKey.hasRecoveryKey {
                        Button("Forgot password?") {
                            showRecovery = true
                            error = nil
                        }
                        .buttonStyle(.plain)
                        .font(Font(MacFont.ui(12.5, weight: .semibold)))
                        .foregroundStyle(theme.ink3)
                    }
                    Button("Reset database") {
                        showWipeConfirm = true
                    }
                    .buttonStyle(.plain)
                    .font(Font(MacFont.ui(12.5, weight: .semibold)))
                    .foregroundStyle(Color(hex: "CE514D"))
                } else {
                    Text("Enter your recovery key to unlock.")
                        .font(Font(MacFont.ui(12.5, weight: .medium)))
                        .foregroundStyle(theme.ink3)
                    TextField("XXXX-XXXX-XXXX-XXXX-XXXX-XXXX", text: $recoveryKeyInput)
                        .textFieldStyle(.plain)
                        .font(.system(size: 15, design: .monospaced).weight(.medium))
                        .padding(.horizontal, 16)
                        .frame(height: 44)
                        .background(theme.surface)
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                        .overlay(RoundedRectangle(cornerRadius: 12).stroke(theme.line, lineWidth: 1))
                        .onSubmit { recoverWithKey() }

                    if let error {
                        Text(error)
                            .font(Font(MacFont.ui(12, weight: .medium)))
                            .foregroundStyle(Color(hex: "CE514D"))
                    }

                    GateButton(theme: theme, label: "Recover", fill: theme.sage) { recoverWithKey() }
                    Button("Back to password") {
                        showRecovery = false
                        error = nil
                    }
                    .buttonStyle(.plain)
                    .font(Font(MacFont.ui(12.5, weight: .semibold)))
                    .foregroundStyle(theme.ink3)
                }
            }
            .frame(width: 340)
        }
        .padding(40)
        .alert("Reset Database?", isPresented: $showWipeConfirm) {
            Button("Reset", role: .destructive) {
                RecoveryKey.wipeDatabase()
                appState.bridge.isInitialized = false
                appState.bridge.hasDbPassword = false
                RustBridge.persistDbPasswordFlag(false)
                RustBridge.promptForPassword = true
                UserDefaults.standard.set(false, forKey: "useTorByDefault")
                RecoveryKey.resetFailureCount()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This will permanently delete all your bookmarks, reading history, progress, and downloaded works. This cannot be undone.")
        }
    }

    private func unlock() {
        error = nil
        if appState.bridge.open(userPassword: password) {
            RecoveryKey.resetFailureCount()
        } else {
            RecoveryKey.recordFailure()
            if RecoveryKey.shouldWipe() {
                RecoveryKey.wipeDatabase()
                appState.bridge.hasDbPassword = false
                RustBridge.persistDbPasswordFlag(false)
                _ = appState.bridge.createWithAutoKey()
                return
            }
            let remaining = RecoveryKey.wipeThreshold > 0
                ? " (\(RecoveryKey.wipeThreshold - RecoveryKey.failureCount) attempts remaining)"
                : ""
            error = "Wrong password.\(remaining)"
            password = ""
        }
    }

    private func recoverWithKey() {
        error = nil
        guard let blob = RecoveryKey.loadEncryptedBlob() else {
            error = "No recovery data found."
            return
        }
        let key = recoveryKeyInput.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        guard let recovered = RecoveryKey.decryptPassword(fromBlob: blob, withRecoveryKey: key) else {
            error = "Invalid recovery key."
            return
        }
        if appState.bridge.open(userPassword: recovered) {
            RecoveryKey.resetFailureCount()
        } else {
            error = "Recovery failed — database may be corrupted."
        }
    }
}

struct GateButton: View {
    @Bindable var theme: AppTheme
    let label: String
    let fill: Color
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(label)
                .font(Font(MacFont.ui(14.5, weight: .bold)))
                .foregroundStyle(theme.onAccent)
                .frame(maxWidth: .infinity)
                .frame(height: 44)
                .background(fill)
                .clipShape(RoundedRectangle(cornerRadius: 12))
        }
        .buttonStyle(.plain)
    }
}
