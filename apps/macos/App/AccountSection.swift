import SwiftUI

/// AO3 account management for the Settings General pane — parity with the
/// iOS flow: first login, multiple accounts with switching, per-account
/// logout (keeps the account) vs. remove (deletes it), and bookmark sync.
/// Passwords are used once for login over the configured transport (Tor when
/// enabled) and never stored; only session tokens are kept.
struct AccountSection: View {
    @Bindable var theme: AppTheme
    @Bindable var appState: AppState

    @State private var username = ""
    @State private var password = ""
    @State private var isWorking = false
    @State private var error: String?
    @State private var showAddForm = false
    @State private var confirmLogoutID: String?
    @State private var confirmRemoveID: String?

    private var accounts: [(id: String, username: String, isActive: Bool)] {
        // ao3AccountCount is observable — reading it makes this view refresh
        // when accounts change.
        _ = appState.ao3AccountCount
        return appState.bridge.getAccounts()
    }

    var body: some View {
        SettingsGroup(theme: theme, label: "AO3 Account") {
            if accounts.isEmpty {
                loginForm
            } else {
                accountsList
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
            Text("Ends the AO3 session but keeps the account here for signing back in.")
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

    private func credentialsFields(buttonLabel: String, action: @escaping () -> Void) -> some View {
        VStack(spacing: 8) {
            TextField("Username", text: $username)
                .textFieldStyle(.roundedBorder)
            SecureField("Password", text: $password)
                .textFieldStyle(.roundedBorder)
                .onSubmit(action)
            if let error {
                Text(error)
                    .font(Font(MacFont.ui(12, weight: .medium)))
                    .foregroundStyle(Color(hex: "CE514D"))
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            Button {
                action()
            } label: {
                Group {
                    if isWorking {
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
            .disabled(isWorking || username.isEmpty || password.isEmpty)
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

    private func accountRow(_ account: (id: String, username: String, isActive: Bool)) -> some View {
        HStack(spacing: 10) {
            Circle()
                .fill(account.isActive ? theme.sage : theme.line2)
                .frame(width: 7, height: 7)
            VStack(alignment: .leading, spacing: 0) {
                Text(account.username)
                    .font(Font(MacFont.ui(13.5, weight: .semibold)))
                    .foregroundStyle(theme.ink)
                Text(account.isActive ? "Active" : "Tap to switch")
                    .font(Font(MacFont.ui(11)))
                    .foregroundStyle(theme.ink3)
            }
            Spacer()
            if account.isActive {
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
        runWorking {
            let success = try await appState.bridge.login(username: username, password: password)
            guard success else {
                error = "Login failed. Check your username and password."
                return
            }
            try? appState.bridge.saveAccount(username: username)
            appState.bridge.saveSessionCookies()
            appState.refreshAO3Username()
            clearForm()
            await appState.loadSubscriptions(force: true)
        }
    }

    private func addAccount() {
        guard !appState.bridge.networkBlocked else {
            error = "Connect to Tor first."
            return
        }
        runWorking {
            _ = try await appState.bridge.addAccount(username: username, password: password)
            appState.refreshAO3Username()
            showAddForm = false
            clearForm()
        }
    }

    private func logout(accountID: String) {
        confirmLogoutID = nil
        Task { @MainActor in
            await appState.bridge.logoutSpecificAccount(accountId: accountID)
            appState.refreshAO3Username()
        }
    }

    private func remove(accountID: String) {
        confirmRemoveID = nil
        appState.bridge.removeAccount(accountId: accountID)
        appState.refreshAO3Username()
    }

    private func runWorking(_ operation: @escaping () async throws -> Void) {
        guard !isWorking else { return }
        isWorking = true
        error = nil
        Task { @MainActor in
            do {
                try await operation()
            } catch {
                let desc = "\(error)"
                if desc.contains("timeout") {
                    self.error = "Request timed out. Try getting a new circuit."
                } else if desc.contains("Login failed") {
                    self.error = "Login failed. Check your credentials."
                } else {
                    self.error = error.localizedDescription
                }
            }
            isWorking = false
        }
    }

    private func clearForm() {
        username = ""
        password = ""
        error = nil
    }
}
