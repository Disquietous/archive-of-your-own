import SwiftUI

struct AccountManagementView: View {
    @Environment(AppTheme.self) private var theme
    @Environment(AppState.self) private var state
    @Environment(NavigationState.self) private var nav
    @Environment(\.dismiss) private var dismiss

    @State private var showAddAccount = false
    /// The source picked in Add account; nil until the user chooses.
    @State private var addSource: String?
    @State private var addUsername = ""
    @State private var addPassword = ""
    @State private var addError: String?
    @State private var isAddingAccount = false

    @State private var removeConfirmId: String?
    @State private var showRemoveConfirm = false
    @State private var logoutConfirmId: String?
    @State private var showLogoutConfirm = false
    @State private var loggingOutAccountId: String?

    /// One account with the source it belongs to.
    private struct Row: Identifiable {
        let account: UAccount
        let group: UAccountGroup
        var id: String { account.id }
    }

    /// Every source that has sign-in, with its accounts. Observable
    /// through `accountsRevision`, which every account change bumps.
    private var groups: [UAccountGroup] { state.accountGroups() }

    /// Every source's accounts, one list.
    private var accounts: [Row] {
        groups.flatMap { group in group.accounts.map { Row(account: $0, group: group) } }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                Spacer().frame(height: 56)

                // Account list
                if accounts.isEmpty {
                    EmptyStateView(
                        systemImage: "person.crop.circle.badge.plus",
                        title: "No accounts",
                        subtitle: "Add an account to sync bookmarks and subscriptions, comment, and rate."
                    )
                    .padding(.top, 20)
                } else {
                    VStack(spacing: 0) {
                        ForEach(accounts, id: \.id) { account in
                            accountRow(account)

                            if account.id != accounts.last?.id {
                                Divider().foregroundStyle(theme.line)
                                    .padding(.horizontal, 14)
                            }
                        }
                    }
                    .background(theme.surface)
                    .clipShape(RoundedRectangle(cornerRadius: Radius.card))
                    .overlay(
                        RoundedRectangle(cornerRadius: Radius.card)
                            .stroke(theme.line, lineWidth: 1)
                    )
                    .padding(.horizontal, theme.pad)
                }

                // The signed-in AO3 account's own bookmarks.
                if state.ao3Username != nil {
                    Button {
                        nav.openAO3Bookmarks()
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: "bookmark.square")
                                .font(.system(size: 16, weight: .medium))
                            Text("My AO3 Bookmarks")
                                .font(Typography.uiBody())
                        }
                        .foregroundStyle(theme.accent)
                    }
                    .padding(.horizontal, theme.pad)
                }

                // Add account
                if showAddAccount {
                    addAccountForm
                        .padding(.horizontal, theme.pad)
                } else {
                    Button {
                        showAddAccount = true
                        addSource = nil
                        state.siteSignInError = nil
                        addUsername = ""
                        addPassword = ""
                        addError = nil
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: "plus.circle.fill")
                                .font(.system(size: 16, weight: .medium))
                            Text("Add account")
                                .font(Typography.uiBody())
                        }
                        .foregroundStyle(theme.accent)
                    }
                    .padding(.horizontal, theme.pad)
                }

                Spacer().frame(height: 40)
            }
        }
        .background(theme.bg)
        .navigationBarBackButtonHidden(true)
        .toolbar(.hidden, for: .tabBar)
        .toolbar(.hidden, for: .navigationBar)
        .overlay(alignment: .top) { topChrome }
        .alert("Remove Account?", isPresented: $showRemoveConfirm) {
            Button("Remove", role: .destructive) {
                if let id = removeConfirmId {
                    state.removeAccount(id)
                    removeConfirmId = nil
                }
            }
            Button("Cancel", role: .cancel) { removeConfirmId = nil }
        } message: {
            Text("This account will be removed from this device.")
        }
        .alert("Log Out?", isPresented: $showLogoutConfirm) {
            Button("Log out", role: .destructive) {
                if let id = logoutConfirmId {
                    performLogout(accountId: id)
                    logoutConfirmId = nil
                }
            }
            Button("Cancel", role: .cancel) { logoutConfirmId = nil }
        } message: {
            Text("Forgets this account's session on this device. The account stays here so you can log back in.")
        }
    }

    // MARK: - Top Chrome

    private var topChrome: some View {
        HStack(spacing: 10) {
            Button { dismiss() } label: {
                Image(systemName: "chevron.left")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(theme.ink)
                    .frame(width: 36, height: 36)
            }
            .buttonStyle(IconButtonPressStyle())

            Text("Accounts")
                .font(Typography.browseTitle())
                .foregroundStyle(theme.ink)

            Spacer()

            PrivacyPillView {
                nav.presentedSheet = .privacy
            }
        }
        .padding(.horizontal, theme.pad)
        .padding(.top, 8)
        .padding(.bottom, 8)
        .background(
            theme.bg.opacity(0.95)
                .shadow(.drop(color: .black.opacity(0.05), radius: 4, y: 2))
        )
    }

    // MARK: - Account Row

    private func accountRow(_ row: Row) -> some View {
        let account = row.account
        return VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(account.username)
                        .font(.custom("HankenGrotesk", size: 15).weight(.semibold))
                        .foregroundStyle(theme.ink)

                    // "ScribbleHub · Active · Logged in" — active is per source.
                    Text(row.group.name + " · " + (account.isActive
                         ? "Active · \(account.loggedIn ? "Logged in" : "Logged out")"
                         : (account.loggedIn ? "Logged in" : "Logged out")))
                        .font(Typography.uiCaption())
                        .foregroundStyle(account.isActive && account.loggedIn ? theme.sage : theme.ink3)
                }

                Spacer()

                if loggingOutAccountId == account.id {
                    ProgressView()
                        .frame(width: 32, height: 32)
                } else if account.isActive && !account.loggedIn {
                    Button {
                        // By password: the reauth sheet. On the site's own
                        // page: that page again.
                        switch row.group.signIn {
                        case .site: Task { await state.signInAtSite(source: row.group.source) }
                        case .credentials, .none: nav.presentedSheet = .reauth
                        }
                    } label: {
                        Text("Log in")
                            .font(Typography.uiSmall())
                            .foregroundStyle(theme.accent)
                            .frame(height: 32)
                    }
                    .buttonStyle(IconButtonPressStyle())
                } else if account.loggedIn {
                    Button {
                        logoutConfirmId = account.id
                        showLogoutConfirm = true
                    } label: {
                        Image(systemName: "rectangle.portrait.and.arrow.right")
                            .font(.system(size: 14, weight: .medium))
                            .foregroundStyle(theme.ink2)
                            .frame(width: 32, height: 32)
                    }
                    .buttonStyle(IconButtonPressStyle())
                }

                Button {
                    removeConfirmId = account.id
                    showRemoveConfirm = true
                } label: {
                    Image(systemName: "trash")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(Color(hex: "CE514D"))
                        .frame(width: 32, height: 32)
                }
                .buttonStyle(IconButtonPressStyle())
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
        }
    }

    // MARK: - Add Account

    /// Add account: the source first, then that source's way of signing in.
    private var addAccountForm: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Add account")
                .font(Typography.uiSmall())
                .foregroundStyle(theme.ink3)

            Picker("Source", selection: $addSource) {
                Text("Choose a source…").tag(String?.none)
                ForEach(groups, id: \.source) { group in
                    Text(group.name).tag(String?.some(group.source))
                }
            }
            .pickerStyle(.menu)
            .tint(theme.accent)
            .onChange(of: addSource) { _, _ in
                addUsername = ""
                addPassword = ""
                addError = nil
                state.siteSignInError = nil
            }

            if let group = groups.first(where: { $0.source == addSource }) {
                switch group.signIn {
                case .credentials: credentialsStep(group)
                case .site: siteStep(group)
                case .none: EmptyView()
                }
            }

            Button { showAddAccount = false } label: {
                Text("Cancel")
                    .font(Typography.smallButtonLabel())
                    .foregroundStyle(theme.ink3)
            }
        }
    }

    /// A source that signs in with a username and password.
    @ViewBuilder private func credentialsStep(_ group: UAccountGroup) -> some View {
        TextField("Username", text: $addUsername)
            .font(Typography.uiBody())
            .textContentType(.username)
            .autocorrectionDisabled()
            .textInputAutocapitalization(.never)
            .padding(10)
            .background(theme.surface2)
            .clipShape(RoundedRectangle(cornerRadius: 8))

        SecureFieldWithToggle(placeholder: "Password", text: $addPassword)
            .font(Typography.uiBody())
            .padding(10)
            .background(theme.surface2)
            .clipShape(RoundedRectangle(cornerRadius: 8))

        if let addError {
            Text(addError)
                .font(Typography.uiCaption())
                .foregroundStyle(Color(hex: "CE514D"))
        }

        Button {
            Task { await performAddAccount() }
        } label: {
            Text(isAddingAccount ? "Signing in…" : "Sign in")
                .font(Typography.smallButtonLabel())
                .foregroundStyle(theme.onAccent)
                .padding(.horizontal, 16)
                .frame(height: 34)
                .background(RoundedRectangle(cornerRadius: Radius.chip).fill(theme.accent))
        }
        .disabled(isAddingAccount || addUsername.isEmpty || addPassword.isEmpty)

        Text("Your password is used once to sign in to \(group.name) and never stored.")
            .font(Typography.uiCaption())
            .foregroundStyle(theme.ink3)
    }

    /// A source that signs in on its own page, shown in a sheet.
    @ViewBuilder private func siteStep(_ group: UAccountGroup) -> some View {
        if let error = state.siteSignInError, error.source == group.source {
            Text(error.message)
                .font(Typography.uiCaption())
                .foregroundStyle(Color(hex: "CE514D"))
        }

        Button {
            Task {
                if await state.signInAtSite(source: group.source) { showAddAccount = false }
            }
        } label: {
            Text(state.siteSignInSource == group.source ? "Signing in…" : "Sign in on \(group.name)")
                .font(Typography.smallButtonLabel())
                .foregroundStyle(theme.onAccent)
                .padding(.horizontal, 16)
                .frame(height: 34)
                .background(RoundedRectangle(cornerRadius: Radius.chip).fill(theme.accent))
        }
        .disabled(state.siteSignInSource != nil || state.bridge.networkBlocked)

        Text("Opens \(group.name)'s own sign-in page. Your password goes only to the site and is never stored; the app keeps the session.")
            .font(Typography.uiCaption())
            .foregroundStyle(theme.ink3)
    }

    // MARK: - Actions

    private func performLogout(accountId: String) {
        loggingOutAccountId = accountId
        Task {
            await state.logOut(accountId: accountId)
            loggingOutAccountId = nil
        }
    }

    private func performAddAccount() async {
        guard !state.bridge.networkBlocked else {
            addError = "Connect to Tor first."
            return
        }
        isAddingAccount = true
        addError = nil
        do {
            _ = try await state.bridge.addAccount(username: addUsername, password: addPassword)
            state.refreshAO3Username()
            showAddAccount = false
        } catch {
            let desc = "\(error)"
            if desc.contains("timeout") {
                addError = "Request timed out. Try getting a new circuit."
            } else if desc.contains("Login failed") {
                addError = "Login failed. Check your credentials."
            } else {
                addError = error.localizedDescription
            }
        }
        isAddingAccount = false
    }

}
