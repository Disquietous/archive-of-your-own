import SwiftUI

struct DatabaseSetupScreen: View {
    @Environment(AppTheme.self) private var theme
    @Environment(AppState.self) private var state

    @State private var password = ""
    @State private var confirmPassword = ""
    @State private var error: String?
    @State private var generatedRecoveryKey: String?
    @State private var useTor = false

    var body: some View {
        ScrollView {
            VStack(spacing: 0) {
                Spacer().frame(height: 60)

                Image(systemName: "lock.shield")
                    .font(.system(size: 44, weight: .medium))
                    .foregroundStyle(theme.sage)
                    .padding(.bottom, 16)

                Text("Protect Your Library")
                    .font(Typography.pageTitle())
                    .foregroundStyle(theme.ink)
                    .padding(.bottom, 6)

                Text("Your reading history and bookmarks are stored\nin an encrypted database on this device.")
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
                        .overlay(RoundedRectangle(cornerRadius: 14).stroke(theme.line, lineWidth: 1))

                    SecureFieldWithToggle(placeholder: "Confirm password", text: $confirmPassword)
                        .font(.custom("HankenGrotesk", size: 16).weight(.medium))
                        .padding(.horizontal, 16)
                        .frame(height: 50)
                        .background(theme.surface)
                        .clipShape(RoundedRectangle(cornerRadius: 14))
                        .overlay(RoundedRectangle(cornerRadius: 14).stroke(theme.line, lineWidth: 1))

                    if let error {
                        Text(error)
                            .font(Typography.uiSmall())
                            .foregroundStyle(Color(hex: "CE514D"))
                    }

                    if generatedRecoveryKey == nil {
                        Button { setPassword() } label: {
                            Text("Set Password")
                                .font(Typography.buttonLabel())
                                .foregroundStyle(theme.onAccent)
                                .frame(maxWidth: .infinity)
                                .frame(height: 50)
                                .background(RoundedRectangle(cornerRadius: Radius.button).fill(theme.sage))
                        }
                        .buttonStyle(ButtonPressStyle())
                    }

                    if let key = generatedRecoveryKey {
                        VStack(spacing: 8) {
                            Text("RECOVERY KEY")
                                .font(Typography.sectionHeader())
                                .tracking(0.08 * 13)
                                .foregroundStyle(theme.ink3)

                            Text(key)
                                .font(.system(size: 20, design: .monospaced).weight(.bold))
                                .foregroundStyle(theme.ink)
                                .multilineTextAlignment(.center)
                                .textSelection(.enabled)

                            Text("Write this down and keep it safe. If you forget your password, this is the only way to recover your data. It will not be shown again.")
                                .font(.custom("HankenGrotesk", size: 12).weight(.medium))
                                .foregroundStyle(Color(hex: "CE514D"))
                                .multilineTextAlignment(.center)
                                .fixedSize(horizontal: false, vertical: true)

                            Button("I've saved my recovery key") {
                                state.bridge.showingRecoveryKey = false
                            }
                            .font(Typography.buttonLabel())
                            .foregroundStyle(theme.onAccent)
                            .frame(maxWidth: .infinity)
                            .frame(height: 50)
                            .background(RoundedRectangle(cornerRadius: Radius.button).fill(theme.accent))
                            .clipShape(RoundedRectangle(cornerRadius: Radius.button))
                            .padding(.top, 8)
                        }
                    }
                }
                .padding(.horizontal, 32)

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
                .padding(.top, 16)
                .padding(.horizontal, 32)
                .onChange(of: useTor) { _, newValue in
                    UserDefaults.standard.set(newValue, forKey: "useTorByDefault")
                }

                VStack(spacing: 12) {
                    Button {
                        RustBridge.promptForPassword = false
                        _ = state.bridge.createWithAutoKey()
                    } label: {
                        Text("Skip — no password")
                            .font(Typography.smallButtonLabel())
                            .foregroundStyle(theme.ink3)
                    }

                    Button {
                        _ = state.bridge.createWithAutoKey()
                    } label: {
                        Text("Ask me later")
                            .font(Typography.smallButtonLabel())
                            .foregroundStyle(theme.ink3)
                    }
                }
                .padding(.top, 28)

                Spacer().frame(height: 40)
            }
        }
        .background(theme.bg)
    }

    private func setPassword() {
        error = nil
        guard !password.isEmpty else { error = "Password cannot be empty."; return }
        guard password == confirmPassword else { error = "Passwords don't match."; return }
        guard password.count >= 4 else { error = "Password must be at least 4 characters."; return }

        if !state.bridge.createWithPassword(password) {
            error = "Failed to create database."
            return
        }

        let key = RecoveryKey.generate()
        if let blob = RecoveryKey.encryptPassword(password, withRecoveryKey: key) {
            RecoveryKey.storeEncryptedBlob(blob)
            generatedRecoveryKey = key
            state.bridge.showingRecoveryKey = true
        }
        RecoveryKey.resetFailureCount()
    }
}
