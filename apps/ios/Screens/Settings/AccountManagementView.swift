import SwiftUI

struct AccountManagementView: View {
    @Environment(AppTheme.self) private var theme
    @Environment(AppState.self) private var state
    @Environment(NavigationState.self) private var nav
    @Environment(\.dismiss) private var dismiss

    @State private var showAddAccount = false
    @State private var addUsername = ""
    @State private var addPassword = ""
    @State private var addError: String?
    @State private var isAddingAccount = false

    @State private var removeConfirmId: String?
    @State private var showRemoveConfirm = false
    @State private var logoutConfirmId: String?
    @State private var showLogoutConfirm = false
    @State private var loggingOutAccountId: String?

    private var accounts: [AO3Account] {
        // Observable reads so the list refreshes when login state changes.
        _ = state.ao3Username
        _ = state.ao3AccountCount
        return state.bridge.getAccounts()
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
                        subtitle: "Add an AO3 account to sync bookmarks, subscriptions, and comments."
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

                // Add account
                if showAddAccount {
                    addAccountForm
                        .padding(.horizontal, theme.pad)
                } else {
                    Button {
                        showAddAccount = true
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
                    state.bridge.removeAccount(accountId: id)
                    state.refreshAO3Username()
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
            Text("Forgets this account's AO3 session on this device. The account stays here so you can log back in.")
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

            Text("AO3 Accounts")
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

    private func accountRow(_ account: AO3Account) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(account.username)
                        .font(.custom("HankenGrotesk", size: 15).weight(.semibold))
                        .foregroundStyle(theme.ink)

                    Text(account.isActive
                         ? "Active · \(account.isLoggedIn ? "Logged in" : "Logged out")"
                         : (account.isLoggedIn ? "Logged in" : "Logged out"))
                        .font(Typography.uiCaption())
                        .foregroundStyle(account.isActive && account.isLoggedIn ? theme.sage : theme.ink3)
                }

                Spacer()

                if loggingOutAccountId == account.id {
                    ProgressView()
                        .frame(width: 32, height: 32)
                } else if account.isActive && !account.isLoggedIn {
                    Button {
                        nav.presentedSheet = .reauth
                    } label: {
                        Text("Log in")
                            .font(Typography.uiSmall())
                            .foregroundStyle(theme.accent)
                            .frame(height: 32)
                    }
                    .buttonStyle(IconButtonPressStyle())
                } else if account.isLoggedIn {
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

    private var addAccountForm: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Add AO3 account")
                .font(Typography.uiSmall())
                .foregroundStyle(theme.ink3)

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

            HStack(spacing: 10) {
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

                Button { showAddAccount = false } label: {
                    Text("Cancel")
                        .font(Typography.smallButtonLabel())
                        .foregroundStyle(theme.ink3)
                }
            }
        }
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
