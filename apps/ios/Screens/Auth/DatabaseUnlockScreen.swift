import SwiftUI

struct DatabaseUnlockScreen: View {
    @Environment(AppTheme.self) private var theme
    @Environment(AppState.self) private var state

    @State private var password = ""
    @State private var error: String?
    @State private var useTor: Bool = UserDefaults.standard.bool(forKey: "useTorByDefault")
    @State private var showRecovery = false
    @State private var recoveryKeyInput = ""
    @State private var showWipeConfirm = false

    var body: some View {
        VStack(spacing: 0) {
            Spacer()

            Image(systemName: "lock.fill")
                .font(.system(size: 44, weight: .medium))
                .foregroundStyle(theme.accent)
                .padding(.bottom, 16)

            Text("Enter Password")
                .font(Typography.pageTitle())
                .foregroundStyle(theme.ink)
                .padding(.bottom, 6)

            Text("Your library is encrypted.\nEnter your password to unlock it.")
                .font(.custom("HankenGrotesk", size: 14).weight(.medium))
                .foregroundStyle(theme.ink3)
                .multilineTextAlignment(.center)
                .padding(.bottom, 28)

            VStack(spacing: 14) {
                SecureFieldWithToggle(placeholder: "Password", text: $password)
                    .font(.custom("HankenGrotesk", size: 16).weight(.medium))
                    .padding(.horizontal, 16)
                    .frame(height: 50)
                    .background(theme.surface)
                    .clipShape(RoundedRectangle(cornerRadius: 14))
                    .overlay(
                        RoundedRectangle(cornerRadius: 14)
                            .stroke(theme.line, lineWidth: 1)
                    )
                    .onSubmit { unlock() }

                if let error {
                    Text(error)
                        .font(Typography.uiSmall())
                        .foregroundStyle(Color(hex: "CE514D"))
                }

                if !showRecovery {
                    Button { unlock() } label: {
                        Text("Unlock")
                            .font(Typography.buttonLabel())
                            .foregroundStyle(theme.onAccent)
                            .frame(maxWidth: .infinity)
                            .frame(height: 50)
                            .background(RoundedRectangle(cornerRadius: Radius.button).fill(theme.accent))
                    }
                    .buttonStyle(ButtonPressStyle())

                    if RecoveryKey.hasRecoveryKey {
                        Button("Forgot password?") {
                            showRecovery = true
                            error = nil
                        }
                        .font(Typography.smallButtonLabel())
                        .foregroundStyle(theme.ink3)
                    }

                    Button("Reset database") {
                        showWipeConfirm = true
                    }
                    .font(Typography.smallButtonLabel())
                    .foregroundStyle(Color(hex: "CE514D"))
                } else {
                    Text("Enter your recovery key to unlock.")
                        .font(Typography.uiSmall())
                        .foregroundStyle(theme.ink3)

                    TextField("XXXX-XXXX-XXXX-XXXX-XXXX-XXXX", text: $recoveryKeyInput)
                        .font(.system(size: 16, design: .monospaced).weight(.medium))
                        .autocapitalization(.allCharacters)
                        .disableAutocorrection(true)
                        .padding(.horizontal, 16)
                        .frame(height: 50)
                        .background(theme.surface)
                        .clipShape(RoundedRectangle(cornerRadius: 14))
                        .overlay(RoundedRectangle(cornerRadius: 14).stroke(theme.line, lineWidth: 1))

                    Button { recoverWithKey() } label: {
                        Text("Recover")
                            .font(Typography.buttonLabel())
                            .foregroundStyle(theme.onAccent)
                            .frame(maxWidth: .infinity)
                            .frame(height: 50)
                            .background(RoundedRectangle(cornerRadius: Radius.button).fill(theme.sage))
                    }
                    .buttonStyle(ButtonPressStyle())

                    Button("Back to password") {
                        showRecovery = false
                        error = nil
                    }
                    .font(Typography.smallButtonLabel())
                    .foregroundStyle(theme.ink3)
                }
            }
            .padding(.horizontal, 32)
            .alert("Reset Database?", isPresented: $showWipeConfirm) {
                Button("Reset", role: .destructive) {
                    RecoveryKey.wipeDatabase()
                    state.bridge.isInitialized = false
                    state.bridge.hasDbPassword = false
                    RustBridge.persistDbPasswordFlag(false)
                    RustBridge.promptForPassword = true
                    UserDefaults.standard.set(false, forKey: "useTorByDefault")
                    RecoveryKey.resetFailureCount()
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("This will permanently delete all your bookmarks, reading history, progress, and downloaded works. This cannot be undone.")
            }

            Toggle(isOn: $useTor) {
                HStack(spacing: 8) {
                    Image(systemName: "shield.checkmark")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(useTor ? theme.sage : theme.ink3)
                    Text("Connect via Tor on launch")
                        .font(Typography.uiBody())
                        .foregroundStyle(theme.ink)
                }
            }
            .tint(theme.sage)
            .padding(.horizontal, 32)
            .padding(.top, 16)
            .onChange(of: useTor) { _, newValue in
                UserDefaults.standard.set(newValue, forKey: "useTorByDefault")
            }

            Spacer()
            Spacer()
        }
        .background(theme.bg)
    }


    private func unlock() {
        error = nil
        if state.bridge.open(userPassword: password) {
            RecoveryKey.resetFailureCount()
        } else {
            RecoveryKey.recordFailure()
            if RecoveryKey.shouldWipe() {
                RecoveryKey.wipeDatabase()
                state.bridge.hasDbPassword = false
                RustBridge.persistDbPasswordFlag(false)
                _ = state.bridge.createWithAutoKey()
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
        guard let recoveredPassword = RecoveryKey.decryptPassword(fromBlob: blob, withRecoveryKey: key) else {
            error = "Invalid recovery key."
            return
        }
        if state.bridge.open(userPassword: recoveredPassword) {
            RecoveryKey.resetFailureCount()
        } else {
            error = "Recovery failed — database may be corrupted."
        }
    }
}
