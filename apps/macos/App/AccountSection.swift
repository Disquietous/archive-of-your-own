import SwiftUI

/// AO3 account management for the Settings General pane — parity with the
/// iOS flow: first login, multiple accounts with switching, per-account
/// logout (local only; keeps the account) vs. remove (deletes it), logging
/// the active account back in, and bookmark sync.
/// Passwords are used once for login over the configured transport (Tor when
/// enabled) and never stored; only session tokens are kept.
struct AccountSection: View {
    @Bindable var theme: AppTheme
    @Bindable var appState: AppState

    @State private var username = ""
    @State private var password = ""
    @State private var showAddForm = false
    @State private var confirmLogoutID: String?
    @State private var confirmRemoveID: String?

    private var accounts: [AO3Account] {
        // ao3AccountCount and ao3Username are observable — reading them makes
        // this view refresh when accounts or login state change.
        _ = appState.ao3AccountCount
        _ = appState.ao3Username
        return appState.bridge.getAccounts()
    }

    private var activeIsLoggedOut: Bool {
        accounts.contains { $0.isActive && !$0.isLoggedIn }
    }

    var body: some View {
        let _ = theme.uiFontScale  // track app text size so fonts refresh live
        SettingsGroup(theme: theme, label: "AO3 Account") {
            if accounts.isEmpty {
                loginForm
            } else {
                accountsList
                if activeIsLoggedOut && !showAddForm {
                    logInActiveForm
                }
                if showAddForm {
                    credentialsFields(buttonLabel: "Add Account") {
                        addAccount()
                    }
                    Button("Cancel") {
                        showAddForm = false
                        clearForm()
                    }
                    .buttonStyle(.plain)
                    .font(Font(MacFont.ui(11.5, weight: .semibold)))
                    .foregroundStyle(theme.ink3)
                    .frame(maxWidth: .infinity)
                } else {
                    ghostButton("Add Another Account", tint: theme.ink) {
                        showAddForm = true
                    }
                }
                if appState.ao3Username != nil {
                    bookmarkSync
                }
            }
        }
        .alert("Log Out of This Account?", isPresented: logoutBinding) {
            Button("Log Out", role: .destructive) {
                if let id = confirmLogoutID { logout(accountID: id) }
            }
            Button("Cancel", role: .cancel) { confirmLogoutID = nil }
        } message: {
            Text("Forgets this account's AO3 session on this device. The account stays here so you can log back in.")
        }
        .alert("Remove This Account?", isPresented: removeBinding) {
            Button("Remove", role: .destructive) {
                if let id = confirmRemoveID { remove(accountID: id) }
            }
            Button("Cancel", role: .cancel) { confirmRemoveID = nil }
        } message: {
            Text("Removes the account and its session from this device. Your library data stays.")
        }
    }

    // MARK: - Pieces

    private var loginForm: some View {
        VStack(spacing: 8) {
            if appState.bridge.networkBlocked {
                SettingsCard(theme: theme) {
                    SettingsInfoRow(theme: theme, label: "Sign in", value: "Connect to Tor first")
                }
            } else {
                credentialsFields(buttonLabel: "Log In") {
                    firstLogin()
                }
                Text("Signing in enables subscriptions, inbox, kudos, and bookmark sync. Your password is used once and never stored.")
                    .font(Font(MacFont.ui(11.5)))
                    .foregroundStyle(theme.ink3)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var logInActiveForm: some View {
        VStack(spacing: 8) {
            if appState.bridge.networkBlocked {
                SettingsCard(theme: theme) {
                    SettingsInfoRow(theme: theme, label: "Log in", value: "Connect to Tor first")
                }
            } else {
                SecureField("Password for \(appState.ao3ActiveAccount ?? "account")", text: $password)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(logInActive)
                if let error = appState.ao3LoginError {
                    Text(error)
                        .font(Font(MacFont.ui(12, weight: .medium)))
                        .foregroundStyle(Color(hex: "CE514D"))
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                Button(action: logInActive) {
                    Group {
                        if appState.ao3LoginInFlight {
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
                .disabled(appState.ao3LoginInFlight || password.isEmpty)
            }
        }
    }

    private func credentialsFields(buttonLabel: String, action: @escaping () -> Void) -> some View {
        VStack(spacing: 8) {
            TextField("Username", text: $username)
                .textFieldStyle(.roundedBorder)
            SecureField("Password", text: $password)
                .textFieldStyle(.roundedBorder)
                .onSubmit(action)
            if let error = appState.ao3LoginError {
                Text(error)
                    .font(Font(MacFont.ui(12, weight: .medium)))
                    .foregroundStyle(Color(hex: "CE514D"))
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            Button {
                action()
            } label: {
                Group {
                    if appState.ao3LoginInFlight {
                        ProgressView().controlSize(.small)
                    } else {
                        Text(buttonLabel)
                            .font(Font(MacFont.ui(13, weight: .bold)))
                    }
                }
                .foregroundStyle(theme.onAccent)
                .frame(maxWidth: .infinity, minHeight: 34)
                .background(theme.accent)
                .clipShape(RoundedRectangle(cornerRadius: 9))
            }
            .buttonStyle(.plain)
            .disabled(appState.ao3LoginInFlight || username.isEmpty || password.isEmpty)
        }
    }

    private var accountsList: some View {
        SettingsCard(theme: theme) {
            ForEach(Array(accounts.enumerated()), id: \.element.id) { index, account in
                if index > 0 {
                    theme.line.frame(height: 1)
                }
                accountRow(account)
            }
        }
    }

    private func accountRow(_ account: AO3Account) -> some View {
        HStack(spacing: 10) {
            Circle()
                .fill(account.isActive ? theme.sage : theme.line2)
                .frame(width: 7, height: 7)
            VStack(alignment: .leading, spacing: 0) {
                Text(account.username)
                    .font(Font(MacFont.ui(13.5, weight: .semibold)))
                    .foregroundStyle(theme.ink)
                Text(rowStatus(account))
                    .font(Font(MacFont.ui(11)))
                    .foregroundStyle(theme.ink3)
            }
            Spacer()
            if account.isActive && account.isLoggedIn {
                Button("Log Out") { confirmLogoutID = account.id }
                    .buttonStyle(.plain)
                    .font(Font(MacFont.ui(11.5, weight: .bold)))
                    .foregroundStyle(Color(hex: "CE514D"))
            }
            Button {
                confirmRemoveID = account.id
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(theme.ink3)
                    .frame(width: 20, height: 20)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Remove account")
        }
        .padding(.vertical, 9)
        .contentShape(Rectangle())
        .onTapGesture {
            guard !account.isActive else { return }
            appState.switchAccount(account.id)
        }
    }

    private func rowStatus(_ account: AO3Account) -> String {
        let login = account.isLoggedIn ? "Logged in" : "Logged out"
        return account.isActive ? "Active · \(login)" : "\(login) · tap to switch"
    }

    private var bookmarkSync: some View {
        VStack(spacing: 8) {
            HStack(spacing: 8) {
                ghostButton("Import Bookmarks", tint: theme.ink) {
                    Task { await appState.importAO3Bookmarks() }
                }
                ghostButton("Push Synced", tint: theme.ink) {
                    Task { await appState.pushAllSyncedBookmarks() }
                }
            }
            if let status = appState.bookmarkSyncTask.statusMessage {
                Text(status)
                    .font(Font(MacFont.ui(11.5)))
                    .foregroundStyle(theme.ink3)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private func ghostButton(_ label: String, tint: Color, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(label)
                .font(Font(MacFont.ui(12.5, weight: .bold)))
                .foregroundStyle(tint)
                .frame(maxWidth: .infinity, minHeight: 32)
                .background(theme.surface)
                .clipShape(RoundedRectangle(cornerRadius: 9))
                .overlay(RoundedRectangle(cornerRadius: 9).stroke(theme.line, lineWidth: 1))
        }
        .buttonStyle(.plain)
    }

    private var logoutBinding: Binding<Bool> {
        Binding(get: { confirmLogoutID != nil }, set: { if !$0 { confirmLogoutID = nil } })
    }

    private var removeBinding: Binding<Bool> {
        Binding(get: { confirmRemoveID != nil }, set: { if !$0 { confirmRemoveID = nil } })
    }

    // MARK: - Actions (mirroring AO3LoginSheet / AccountManagementView)

    private func firstLogin() {
        Task { @MainActor in
            if await appState.signInAO3(username: username, password: password) {
                clearForm()
            }
        }
    }

    private func addAccount() {
        Task { @MainActor in
            if await appState.addAO3Account(username: username, password: password) {
                showAddForm = false
                clearForm()
            }
        }
    }

    private func logout(accountID: String) {
        confirmLogoutID = nil
        Task { @MainActor in
            await appState.logOut(accountId: accountID)
        }
    }

    private func logInActive() {
        guard !password.isEmpty else { return }
        Task { @MainActor in
            if await appState.logInActiveAccount(password: password) {
                clearForm()
            }
        }
    }

    private func remove(accountID: String) {
        confirmRemoveID = nil
        appState.bridge.removeAccount(accountId: accountID)
        appState.refreshAO3Username()
    }

    private func clearForm() {
        username = ""
        password = ""
        appState.ao3LoginError = nil
    }
}
