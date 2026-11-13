import SwiftUI

/// Account management for the Settings General pane — every source's
/// accounts in one list: switching (active is per source), per-account
/// logout (local only; keeps the account) vs. remove (deletes it), signing
/// a logged-out account back in, and AO3 bookmark sync. Add Account starts
/// by choosing the source; the step after that follows how that source
/// signs in — a username and password the app sends once and never stores
/// (over the configured transport), or the site's own sign-in page in a
/// sheet. Only session tokens are kept.
struct AccountSection: View {
    @Bindable var theme: AppTheme
    @Bindable var appState: AppState

    @State private var username = ""
    @State private var password = ""
    @State private var showAddForm = false
    /// The source picked in Add Account; nil until the user chooses.
    @State private var addSource: String?
    @State private var confirmLogoutID: String?
    @State private var confirmRemoveID: String?

    /// One account with the source it belongs to.
    private struct Row: Identifiable {
        let account: UAccount
        let group: UAccountGroup
        var id: String { account.id }
    }

    /// Every source that has sign-in, with its accounts. Observable
    /// through `accountsRevision`, which every account change bumps.
    private var groups: [UAccountGroup] { appState.accountGroups() }

    private var rows: [Row] {
        groups.flatMap { group in group.accounts.map { Row(account: $0, group: group) } }
    }

    /// An active account that signs in by password is logged out — the
    /// password field for it shows under the list.
    private var activeIsLoggedOut: Bool {
        rows.contains { $0.group.signIn == .credentials && $0.account.isActive && !$0.account.loggedIn }
    }

    var body: some View {
        let _ = theme.uiFontScale  // track app text size so fonts refresh live
        SettingsGroup(theme: theme, label: "Accounts") {
            if !rows.isEmpty {
                accountsList
                if activeIsLoggedOut && !showAddForm {
                    logInActiveForm
                }
            }
            if rows.isEmpty || showAddForm {
                addAccountForm
                if !rows.isEmpty {
                    Button("Cancel") { closeAddForm() }
                        .buttonStyle(.plain)
                        .font(Font(MacFont.ui(11.5, weight: .semibold)))
                        .foregroundStyle(theme.ink3)
                        .frame(maxWidth: .infinity)
                }
            } else {
                ghostButton("Add Account", tint: theme.ink) {
                    clearForm()
                    showAddForm = true
                }
            }
            if appState.ao3Username != nil {
                bookmarkSync
            }
        }
        .alert("Log Out of This Account?", isPresented: logoutBinding) {
            Button("Log Out", role: .destructive) {
                if let id = confirmLogoutID { logout(accountID: id) }
            }
            Button("Cancel", role: .cancel) { confirmLogoutID = nil }
        } message: {
            Text("Forgets this account's session on this device. The account stays here so you can log back in.")
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

    /// Add Account: the source first, then that source's way of signing in.
    private var addAccountForm: some View {
        VStack(spacing: 8) {
            if appState.bridge.networkBlocked {
                SettingsCard(theme: theme) {
                    SettingsInfoRow(theme: theme, label: "Sign in", value: appState.bridge.privacyStatus.connectHint)
                }
            } else {
                HStack(spacing: 10) {
                    Text("Source")
                        .font(Font(MacFont.ui(13, weight: .medium)))
                        .foregroundStyle(theme.ink)
                    Spacer()
                    Picker("Source", selection: $addSource) {
                        Text("Choose a source…").tag(String?.none)
                        ForEach(groups, id: \.source) { group in
                            Text(group.name).tag(String?.some(group.source))
                        }
                    }
                    .labelsHidden()
                    .fixedSize()
                    .onChange(of: addSource) { _, _ in
                        username = ""
                        password = ""
                        appState.ao3LoginError = nil
                        appState.siteSignInError = nil
                    }
                }
                if let group = groups.first(where: { $0.source == addSource }) {
                    switch group.signIn {
                    case .credentials:
                        credentialsFields(buttonLabel: "Log In") {
                            group.accounts.isEmpty ? firstLogin() : addAccount()
                        }
                        note("Your password is used once to sign in to \(group.name) and never stored.")
                    case .site:
                        siteSignIn(group)
                        note("Opens \(group.name)'s own sign-in page. Your password goes only to the site and is never stored; the app keeps the session.")
                    case .none:
                        EmptyView()
                    }
                }
            }
        }
    }

    /// The step for a source that signs in on its own page.
    private func siteSignIn(_ group: UAccountGroup) -> some View {
        VStack(spacing: 8) {
            if let error = appState.siteSignInError, error.source == group.source {
                Text(error.message)
                    .font(Font(MacFont.ui(12, weight: .medium)))
                    .foregroundStyle(Color(hex: "CE514D"))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Button {
                signInOnSite(group.source)
            } label: {
                Group {
                    if appState.siteSignInSource == group.source {
                        ProgressView().controlSize(.small)
                    } else {
                        Text("Sign In on \(group.name)…")
                            .font(Font(MacFont.ui(13, weight: .bold)))
                    }
                }
                .foregroundStyle(theme.onAccent)
                .frame(maxWidth: .infinity, minHeight: 34)
                .background(theme.accent)
                .clipShape(RoundedRectangle(cornerRadius: 9))
            }
            .buttonStyle(.plain)
            .disabled(appState.siteSignInSource != nil)
        }
    }

    private func note(_ text: String) -> some View {
        Text(text)
            .font(Font(MacFont.ui(11.5)))
            .foregroundStyle(theme.ink3)
            .frame(maxWidth: .infinity, alignment: .leading)
            .fixedSize(horizontal: false, vertical: true)
    }

    private var logInActiveForm: some View {
        VStack(spacing: 8) {
            if appState.bridge.networkBlocked {
                SettingsCard(theme: theme) {
                    SettingsInfoRow(theme: theme, label: "Log in", value: appState.bridge.privacyStatus.connectHint)
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
            ForEach(Array(rows.enumerated()), id: \.element.id) { index, row in
                if index > 0 {
                    theme.line.frame(height: 1)
                }
                accountRow(row)
            }
        }
    }

    private func accountRow(_ row: Row) -> some View {
        let account = row.account
        return HStack(spacing: 10) {
            Circle()
                .fill(account.isActive ? theme.sage : theme.line2)
                .frame(width: 7, height: 7)
            VStack(alignment: .leading, spacing: 0) {
                Text(account.username)
                    .font(Font(MacFont.ui(13.5, weight: .semibold)))
                    .foregroundStyle(theme.ink)
                Text(rowStatus(row))
                    .font(Font(MacFont.ui(11)))
                    .foregroundStyle(theme.ink3)
            }
            Spacer()
            if account.isActive && account.loggedIn {
                Button("Log Out") { confirmLogoutID = account.id }
                    .buttonStyle(.plain)
                    .font(Font(MacFont.ui(11.5, weight: .bold)))
                    .foregroundStyle(Color(hex: "CE514D"))
            } else if account.isActive && row.group.signIn == .site {
                // Signed out of a site that signs in on its own page.
                Button("Log In") { signInOnSite(row.group.source) }
                    .buttonStyle(.plain)
                    .font(Font(MacFont.ui(11.5, weight: .bold)))
                    .foregroundStyle(theme.accent)
                    .disabled(appState.siteSignInSource != nil || appState.bridge.networkBlocked)
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

    /// "ScribbleHub · Active · Logged in" — active is per source.
    private func rowStatus(_ row: Row) -> String {
        let login = row.account.loggedIn ? "Logged in" : "Logged out"
        let state = row.account.isActive ? "Active · \(login)" : "\(login) · tap to switch"
        return "\(row.group.name) · \(state)"
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
                closeAddForm()
            }
        }
    }

    private func addAccount() {
        Task { @MainActor in
            if await appState.addAO3Account(username: username, password: password) {
                closeAddForm()
            }
        }
    }

    private func signInOnSite(_ source: String) {
        Task { @MainActor in
            if await appState.signInAtSite(source: source) {
                closeAddForm()
            }
        }
    }

    private func closeAddForm() {
        showAddForm = false
        clearForm()
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
        appState.removeAccount(accountID)
    }

    private func clearForm() {
        username = ""
        password = ""
        addSource = nil
        appState.ao3LoginError = nil
        appState.siteSignInError = nil
    }
}
