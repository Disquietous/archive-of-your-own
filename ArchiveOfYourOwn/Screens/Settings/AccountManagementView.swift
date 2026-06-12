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

    @State private var editingPasswordFor: String?
    @State private var newPassword = ""
    @State private var passwordUpdateError: String?
    @State private var passwordUpdated = false

    @State private var removeConfirmId: String?
    @State private var showRemoveConfirm = false

    private var accounts: [(id: String, username: String, isActive: Bool)] {
        state.bridge.getAccounts()
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

                // Password edit form
                if let editId = editingPasswordFor,
                   let account = accounts.first(where: { $0.id == editId }) {
                    passwordEditForm(account)
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
            Text("This account's credentials will be removed from this device.")
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

    private func accountRow(_ account: (id: String, username: String, isActive: Bool)) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(account.username)
                        .font(.custom("HankenGrotesk", size: 15).weight(.semibold))
                        .foregroundStyle(theme.ink)

                    if account.isActive {
                        Text("Active")
                            .font(Typography.uiCaption())
                            .foregroundStyle(theme.sage)
                    }
                }

                Spacer()

                // Update password
                Button {
                    if editingPasswordFor == account.id {
                        editingPasswordFor = nil
                    } else {
                        editingPasswordFor = account.id
                        newPassword = ""
                        passwordUpdateError = nil
                        passwordUpdated = false
                    }
                } label: {
                    Image(systemName: "key")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(theme.ink2)
                        .frame(width: 32, height: 32)
                }
                .buttonStyle(IconButtonPressStyle())

                // Remove
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

    // MARK: - Password Edit

    private func passwordEditForm(_ account: (id: String, username: String, isActive: Bool)) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Update password for \(account.username)")
                .font(Typography.uiSmall())
                .foregroundStyle(theme.ink3)

            SecureFieldWithToggle(placeholder: "New password", text: $newPassword)
                .font(Typography.uiBody())
                .padding(10)
                .background(theme.surface2)
                .clipShape(RoundedRectangle(cornerRadius: 8))

            if let passwordUpdateError {
                Text(passwordUpdateError)
                    .font(Typography.uiCaption())
                    .foregroundStyle(Color(hex: "CE514D"))
            }

            if passwordUpdated {
                Text("Password updated.")
                    .font(Typography.uiCaption())
                    .foregroundStyle(theme.sage)
            }

            HStack(spacing: 10) {
                Button {
                    updatePassword(accountId: account.id, username: account.username)
                } label: {
                    Text("Save")
                        .font(Typography.smallButtonLabel())
                        .foregroundStyle(theme.onAccent)
                        .padding(.horizontal, 16)
                        .frame(height: 34)
                        .background(RoundedRectangle(cornerRadius: Radius.chip).fill(theme.accent))
                }
                .disabled(newPassword.isEmpty)

                Button {
                    editingPasswordFor = nil
                } label: {
                    Text("Cancel")
                        .font(Typography.smallButtonLabel())
                        .foregroundStyle(theme.ink3)
                }
            }
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

    private func updatePassword(accountId: String, username: String) {
        passwordUpdateError = nil
        passwordUpdated = false
        do {
            try state.bridge.saveCredentials(username: username, password: newPassword)
            passwordUpdated = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                editingPasswordFor = nil
            }
        } catch {
            passwordUpdateError = error.localizedDescription
        }
    }
}
