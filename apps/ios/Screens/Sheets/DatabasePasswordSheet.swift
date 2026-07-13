import SwiftUI

struct DatabasePasswordSheet: View {
    @Environment(AppTheme.self) private var theme
    @Environment(AppState.self) private var state
    @Environment(\.dismiss) private var dismiss

    @State private var password = ""
    @State private var confirmPassword = ""
    @State private var error: String?
    @State private var success = false
    @State private var useTor = false
    @State private var isConnectingTor = false
    @State private var generatedRecoveryKey: String?

    var isReset: Bool = false

    var body: some View {
        VStack(spacing: 0) {
            RoundedRectangle(cornerRadius: 3)
                .fill(theme.line2)
                .frame(width: 36, height: 5)
                .padding(.top, 10)
                .padding(.bottom, 20)

            Image(systemName: "lock.shield")
                .font(.system(size: 36, weight: .medium))
                .foregroundStyle(theme.sage)
                .padding(.bottom, 12)

            Text(isReset ? "Set Database Password" : "Protect Your Library")
                .font(Typography.sheetTitle())
                .foregroundStyle(theme.ink)
                .padding(.bottom, 6)

            Text("Your reading history and bookmarks are stored in an encrypted database on this device.")
                .font(.custom("HankenGrotesk", size: 13.5).weight(.medium))
                .foregroundStyle(theme.ink3)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 24)
                .padding(.bottom, 20)

            VStack(spacing: 12) {
                SecureFieldWithToggle(placeholder: "Password", text: $password)
                    .font(.custom("HankenGrotesk", size: 15).weight(.medium))
                    .padding(.horizontal, 14)
                    .frame(height: 46)
                    .background(theme.surface2)
                    .clipShape(RoundedRectangle(cornerRadius: 12))

                SecureFieldWithToggle(placeholder: "Confirm password", text: $confirmPassword)
                    .font(.custom("HankenGrotesk", size: 15).weight(.medium))
                    .padding(.horizontal, 14)
                    .frame(height: 46)
                    .background(theme.surface2)
                    .clipShape(RoundedRectangle(cornerRadius: 12))

                if let error {
                    Text(error)
                        .font(Typography.uiSmall())
                        .foregroundStyle(Color(hex: "CE514D"))
                        .fixedSize(horizontal: false, vertical: true)
                }

                if success {
                    Text("Password set successfully.")
                        .font(Typography.uiSmall())
                        .foregroundStyle(theme.sage)
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
                            generatedRecoveryKey = nil
                            dismiss()
                        }
                        .font(Typography.smallButtonLabel())
                        .foregroundStyle(theme.accent)
                        .padding(.top, 4)
                    }
                    .padding(.top, 8)
                }
            }
            .padding(.horizontal, 20)

            if !isReset {
                VStack(spacing: 8) {
                    Toggle(isOn: $useTor) {
                        HStack(spacing: 8) {
                            Image(systemName: "shield.checkmark")
                                .font(.system(size: 14, weight: .semibold))
                                .foregroundStyle(useTor ? theme.sage : theme.ink3)
                            Text("Connect via Tor")
                                .font(Typography.uiBody())
                                .foregroundStyle(theme.ink)
                        }
                    }
                    .tint(theme.sage)
                    .padding(.horizontal, 20)
                    .padding(.top, 16)

                    if useTor {
                        if isConnectingTor {
                            HStack(spacing: 8) {
                                ProgressView()
                                    .tint(theme.sage)
                                Text(state.torStatus == .connecting ? "Connecting to Tor…" : "Connected")
                                    .font(Typography.uiSmall())
                                    .foregroundStyle(theme.ink3)
                            }
                            .padding(.top, 4)
                        } else if state.torStatus.isConnected {
                            HStack(spacing: 6) {
                                Circle()
                                    .fill(theme.sage)
                                    .frame(width: 7, height: 7)
                                Text("Connected through Tor")
                                    .font(Typography.uiSmall())
                                    .foregroundStyle(theme.sage)
                            }
                            .padding(.top, 4)
                        }
                    }
                }
                .onChange(of: useTor) { _, newValue in
                    if newValue && !state.torStatus.isConnected {
                        isConnectingTor = true
                        Task {
                            await state.connectTor()
                            isConnectingTor = false
                        }
                    }
                    theme.useTorByDefault = newValue
                }
            }

            Spacer()

            VStack(spacing: 10) {
                Button {
                    setPassword()
                } label: {
                    Text("Set Password")
                        .font(Typography.buttonLabel())
                        .foregroundStyle(theme.onAccent)
                        .frame(maxWidth: .infinity)
                        .frame(height: 48)
                        .background(RoundedRectangle(cornerRadius: Radius.button).fill(theme.sage))
                }
                .buttonStyle(ButtonPressStyle())

                if !isReset {
                    Button {
                        RustBridge.promptForPassword = false
                        if !state.bridge.isInitialized {
                            _ = state.bridge.createWithAutoKey()
                        }
                        dismiss()
                    } label: {
                        Text("Skip — leave unprotected")
                            .font(Typography.smallButtonLabel())
                            .foregroundStyle(theme.ink3)
                            .frame(maxWidth: .infinity)
                            .frame(height: 40)
                    }
                }

                if isReset {
                    Button {
                        removePassword()
                    } label: {
                        Text("Remove password")
                            .font(Typography.smallButtonLabel())
                            .foregroundStyle(Color(hex: "CE514D"))
                            .frame(maxWidth: .infinity)
                            .frame(height: 40)
                    }
                }

                Button {
                    if !isReset && !state.bridge.isInitialized {
                        _ = state.bridge.createWithAutoKey()
                    }
                    dismiss()
                } label: {
                    Text(isReset ? "Cancel" : "Ask me later")
                        .font(Typography.smallButtonLabel())
                        .foregroundStyle(theme.ink3)
                        .frame(maxWidth: .infinity)
                        .frame(height: 36)
                }
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 16)
        }
        .background(theme.surface)
        .clipShape(RoundedRectangle(cornerRadius: Radius.sheet))
        .presentationDetents([.large])
        .presentationDragIndicator(.hidden)
    }

    private func setPassword() {
        error = nil
        success = false

        guard !password.isEmpty else {
            error = "Password cannot be empty."
            return
        }
        guard password == confirmPassword else {
            error = "Passwords don't match."
            return
        }
        guard password.count >= 4 else {
            error = "Password must be at least 4 characters."
            return
        }

        if state.bridge.changePassword(to: password) {
            let key = RecoveryKey.generate()
            if let blob = RecoveryKey.encryptPassword(password, withRecoveryKey: key) {
                RecoveryKey.storeEncryptedBlob(blob)
                generatedRecoveryKey = key
            }
            RecoveryKey.resetFailureCount()
            success = true
            if generatedRecoveryKey == nil {
                DispatchQueue.main.asyncAfter(deadline: .now() + 1) { dismiss() }
            }
        } else {
            error = "Failed to change password."
        }
    }

    private func removePassword() {
        error = nil
        success = false
        guard !password.isEmpty else {
            error = "Enter your current password to confirm removal."
            return
        }
        // Verify by trying to open the DB with the entered password
        if !state.bridge.verifyPassword(password) {
            error = "Wrong password."
            return
        }
        if state.bridge.removePassword() {
            RecoveryKey.deleteEncryptedBlob()
            success = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                dismiss()
            }
        } else {
            error = "Failed to remove password."
        }
    }
}

#Preview {
    Color.clear
        .sheet(isPresented: .constant(true)) {
            DatabasePasswordSheet()
                .environment(AppTheme())
                .environment(AppState())
        }
}
