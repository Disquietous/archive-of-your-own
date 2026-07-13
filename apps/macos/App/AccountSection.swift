import SwiftUI

/// AO3 account sign-in for the Settings General pane. Login happens over the
/// configured transport (Tor when enabled) via the Rust client, matching iOS.
struct AccountSection: View {
    @Bindable var theme: AppTheme
    @Bindable var appState: AppState

    @State private var username = ""
    @State private var password = ""
    @State private var isLoggingIn = false
    @State private var error: String?

    var body: some View {
        SettingsGroup(theme: theme, label: "AO3 Account") {
            if let account = appState.ao3Username {
                SettingsCard(theme: theme) {
                    SettingsInfoRow(theme: theme, label: "Signed in as", value: account)
                    if appState.ao3AccountCount > 1 {
                        theme.line.frame(height: 1)
                        SettingsInfoRow(theme: theme, label: "Accounts", value: "\(appState.ao3AccountCount)")
                    }
                }
                Button {
                    logOut()
                } label: {
                    Text("Log Out")
                        .font(Font(MacFont.ui(13, weight: .bold)))
                        .foregroundStyle(Color(hex: "CE514D"))
                        .frame(maxWidth: .infinity, minHeight: 34)
                        .background(theme.surface)
                        .clipShape(RoundedRectangle(cornerRadius: 9))
                        .overlay(RoundedRectangle(cornerRadius: 9).stroke(theme.line, lineWidth: 1))
                }
                .buttonStyle(.plain)
            } else if appState.bridge.networkBlocked {
                SettingsCard(theme: theme) {
                    SettingsInfoRow(theme: theme, label: "Sign in",
                                    value: "Connect to Tor first")
                }
            } else {
                VStack(spacing: 8) {
                    TextField("Username", text: $username)
                        .textFieldStyle(.roundedBorder)
                    SecureField("Password", text: $password)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit { logIn() }
                    if let error {
                        Text(error)
                            .font(Font(MacFont.ui(12, weight: .medium)))
                            .foregroundStyle(Color(hex: "CE514D"))
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    Button {
                        logIn()
                    } label: {
                        Group {
                            if isLoggingIn {
                                ProgressView().controlSize(.small)
                            } else {
                                Text("Log In")
                                    .font(Font(MacFont.ui(13, weight: .bold)))
                            }
                        }
                        .foregroundStyle(theme.onAccent)
                        .frame(maxWidth: .infinity, minHeight: 34)
                        .background(theme.accent)
                        .clipShape(RoundedRectangle(cornerRadius: 9))
                    }
                    .buttonStyle(.plain)
                    .disabled(isLoggingIn || username.isEmpty || password.isEmpty)
                    Text("Your password is used once to sign in and is not stored. Only the session token is kept, in your encrypted library.")
                        .font(Font(MacFont.ui(11.5)))
                        .foregroundStyle(theme.ink3)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private func logIn() {
        guard !isLoggingIn, !username.isEmpty, !password.isEmpty else { return }
        isLoggingIn = true
        error = nil
        Task { @MainActor in
            do {
                let success = try await appState.bridge.login(username: username, password: password)
                if success {
                    try? appState.bridge.saveAccount(username: username)
                    appState.bridge.saveSessionCookies()
                    appState.refreshAO3Username()
                    password = ""
                    username = ""
                    await appState.loadSubscriptions(force: true)
                } else {
                    error = "Login failed. Check your username and password."
                }
            } catch {
                self.error = error.localizedDescription
            }
            isLoggingIn = false
        }
    }

    private func logOut() {
        Task { @MainActor in
            await appState.bridge.logoutAccount()
            appState.refreshAO3Username()
            appState.subscriptions = []
            appState.subscriptionsLoadedForAccount = nil
        }
    }
}
