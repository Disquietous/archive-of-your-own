import SwiftUI

struct PrivacySheetView: View {
    @Environment(AppTheme.self) private var theme
    @Environment(AppState.self) private var state
    @Environment(NavigationState.self) private var nav
    @Environment(\.dismiss) private var dismiss

    @State private var circuitTask: Task<Void, Never>?
    @State private var showAddAccount = false
    @State private var addUsername = ""
    @State private var addPassword = ""
    @State private var addError: String?
    @State private var isAddingAccount = false
    @State private var showLogoutConfirm = false
    @State private var isLoggingOut = false

    private var isInProgress: Bool {
        state.bridge.torStatus == .connecting || state.isTestingCircuit || state.isResolvingCloudflare
    }

    private var isPrivate: Bool {
        state.bridge.torStatus.isConnected && !isInProgress
    }

    private var accounts: [(id: String, username: String, isActive: Bool)] {
        state.bridge.getAccounts()
    }

    private var activeUsername: String {
        accounts.first(where: \.isActive)?.username ?? "Guest"
    }

    var body: some View {
        VStack(spacing: 0) {
            RoundedRectangle(cornerRadius: 3)
                .fill(theme.line2)
                .frame(width: 36, height: 5)
                .padding(.top, 10)
                .padding(.bottom, 12)

            ScrollView {
                VStack(spacing: 16) {
                    // Account selector + inbox
                    accountRow

                    // Add account form
                    if showAddAccount {
                        addAccountForm
                            .padding(.horizontal, theme.pad)
                    }

                    // Tor status
                    torSection

                    // Tor blocked warning
                    if state.bridge.networkBlocked {
                        blockedWarning
                    }

                    // Actions
                    actionButtons
                }
                .padding(.bottom, 16)
            }

            // Close button
            Button { dismiss() } label: {
                Text("Close")
                    .font(Typography.smallButtonLabel())
                    .foregroundStyle(theme.ink2)
                    .frame(maxWidth: .infinity)
                    .frame(height: 40)
            }
            .padding(.bottom, 8)
        }
        .background(theme.surface)
        .clipShape(RoundedRectangle(cornerRadius: Radius.sheet))
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.hidden)
        .alert("Log Out?", isPresented: $showLogoutConfirm) {
            Button("Log out", role: .destructive) {
                isLoggingOut = true
                Task {
                    await state.bridge.logoutAccount()
                    state.refreshAO3Username()
                    isLoggingOut = false
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("The session will be ended on AO3. You'll need to sign in again to use this account.")
        }
    }

    // MARK: - Account Row

    private var accountRow: some View {
        HStack(spacing: 12) {
            // Account dropdown
            Menu {
                ForEach(accounts, id: \.id) { account in
                    Button {
                        if !account.isActive {
                            state.switchAccount(account.id)
                        }
                    } label: {
                        HStack {
                            Text(account.username)
                            if account.isActive {
                                Image(systemName: "checkmark")
                            }
                        }
                    }
                }

                Divider()

                Button {
                    showAddAccount = true
                    addUsername = ""
                    addPassword = ""
                    addError = nil
                } label: {
                    Label("Add account", systemImage: "plus")
                }

                if state.ao3Username != nil {
                    Button(role: .destructive) {
                        showLogoutConfirm = true
                    } label: {
                        Label("Log out", systemImage: "rectangle.portrait.and.arrow.right")
                    }
                }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "person.crop.circle")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(theme.ink2)
                    Text(activeUsername)
                        .font(.custom("HankenGrotesk", size: 14).weight(.semibold))
                        .foregroundStyle(theme.ink)
                        .lineLimit(1)
                    Image(systemName: "chevron.up.chevron.down")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(theme.ink3)
                }
                .padding(.horizontal, 14)
                .frame(height: 40)
                .background(theme.surface2)
                .clipShape(RoundedRectangle(cornerRadius: 10))
            }

            Spacer()

            // Inbox button
            if state.ao3Username != nil {
                Button {
                    nav.openInbox()
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "tray")
                            .font(.system(size: 14, weight: .semibold))
                        Text("Inbox")
                            .font(.custom("HankenGrotesk", size: 14).weight(.semibold))
                        if state.inboxUnreadCount > 0 {
                            Text("\(state.inboxUnreadCount)")
                                .font(.custom("HankenGrotesk", size: 11).weight(.bold))
                                .foregroundStyle(.white)
                                .padding(.horizontal, 5)
                                .frame(minWidth: 18, minHeight: 18)
                                .background(Color(hex: "CE514D"))
                                .clipShape(Capsule())
                        }
                    }
                    .foregroundStyle(theme.ink)
                    .padding(.horizontal, 14)
                    .frame(height: 40)
                    .background(theme.surface2)
                    .clipShape(RoundedRectangle(cornerRadius: 10))
                }
            }
        }
        .padding(.horizontal, theme.pad)
    }

    // MARK: - Add Account Form

    private var addAccountForm: some View {
        VStack(alignment: .leading, spacing: 8) {
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
                    Task { await addAccount() }
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

    // MARK: - Tor Section

    private var torSection: some View {
        VStack(spacing: 8) {
            HStack(spacing: 10) {
                Circle()
                    .fill(isInProgress ? theme.accent2 : (isPrivate ? theme.sage : theme.ink3))
                    .frame(width: 10, height: 10)
                    .shadow(color: (isPrivate ? theme.sage : theme.ink3).opacity(0.4), radius: 4)

                Text(statusTitle)
                    .font(.custom("HankenGrotesk", size: 15).weight(.semibold))
                    .foregroundStyle(theme.ink)

                Spacer()

                Text(statusSubtitle)
                    .font(Typography.uiSmall())
                    .foregroundStyle(theme.ink3)
            }
            .padding(.horizontal, theme.pad)

            TorCircuitView()
                .padding(.horizontal, theme.pad + 8)
        }
    }

    // MARK: - Blocked Warning

    private var blockedWarning: some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(Color(hex: "CE514D"))
            Text("Tor is enabled in settings but not connected. Network requests are blocked.")
                .font(.custom("HankenGrotesk", size: 13).weight(.medium))
                .foregroundStyle(theme.ink2)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(12)
        .background(theme.surface2)
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .padding(.horizontal, theme.pad)
    }

    // MARK: - Action Buttons

    private var actionButtons: some View {
        VStack(spacing: 10) {
            switch state.bridge.torStatus {
            case .disconnected, .error:
                Button {
                    Task { await state.connectTor() }
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "shield.checkmark")
                            .font(.system(size: 14, weight: .semibold))
                        Text("Connect via Tor")
                            .font(Typography.buttonLabel())
                    }
                    .foregroundStyle(theme.onAccent)
                    .frame(maxWidth: .infinity)
                    .frame(height: 46)
                    .background(RoundedRectangle(cornerRadius: Radius.button).fill(theme.sage))
                }
                .buttonStyle(ButtonPressStyle())

            case .connecting:
                HStack(spacing: 10) {
                    ProgressView().tint(theme.sage)
                    Text("Bootstrapping Tor…")
                        .font(Typography.uiBody())
                        .foregroundStyle(theme.ink2)
                }
                .frame(maxWidth: .infinity).frame(height: 46)

            case .connected where state.isTestingCircuit:
                VStack(spacing: 8) {
                    HStack(spacing: 10) {
                        ProgressView().tint(theme.sage)
                        Text("Testing circuit… (attempt \(state.circuitAttempt))")
                            .font(Typography.uiBody())
                            .foregroundStyle(theme.ink2)
                    }
                    Button {
                        state.cancelTorConnect()
                    } label: {
                        Text("Stop searching")
                            .font(Typography.smallButtonLabel())
                            .foregroundStyle(theme.ink3)
                    }
                }

            case .connected where state.isResolvingCloudflare:
                HStack(spacing: 10) {
                    ProgressView().tint(theme.sage)
                    Text("Passing Cloudflare check…")
                        .font(Typography.uiBody())
                        .foregroundStyle(theme.ink2)
                }
                .frame(maxWidth: .infinity).frame(height: 46)

            case .connected:
                Button {
                    circuitTask = Task { await state.connectTor() }
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "arrow.triangle.2.circlepath")
                            .font(.system(size: 13, weight: .semibold))
                        Text("New circuit")
                            .font(Typography.smallButtonLabel())
                    }
                    .foregroundStyle(theme.ink)
                    .frame(maxWidth: .infinity)
                    .frame(height: 40)
                    .background(RoundedRectangle(cornerRadius: Radius.button).stroke(theme.line, lineWidth: 1))
                }
                .buttonStyle(ButtonPressStyle())
            }
        }
        .padding(.horizontal, theme.pad)
    }

    // MARK: - Add Account

    private func addAccount() async {
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
                addError = "Request timed out. Try getting a new circuit first."
            } else if desc.contains("Login failed") {
                addError = "Login failed. Check your credentials."
            } else {
                addError = error.localizedDescription
            }
        }
        isAddingAccount = false
    }

    // MARK: - Status

    private var statusTitle: String {
        if isInProgress { return "Connecting" }
        switch state.bridge.torStatus {
        case .connected: return "Private"
        case .connecting: return "Connecting"
        case .disconnected: return "Direct"
        case .error: return "Error"
        }
    }

    private var statusSubtitle: String {
        if state.isTestingCircuit { return "Testing exit node… (\(state.circuitAttempt))" }
        if state.isResolvingCloudflare { return "Cloudflare…" }
        switch state.bridge.torStatus {
        case .connected where isPrivate: return "3-hop circuit active"
        case .connected: return "Establishing…"
        case .connecting: return "Establishing…"
        case .disconnected: return "Not routed through Tor"
        case .error(let msg): return msg
        }
    }
}

private struct SpinModifier: ViewModifier {
    @State private var rotation: Double = 0

    func body(content: Content) -> some View {
        content
            .rotationEffect(.degrees(rotation))
            .onAppear {
                withAnimation(.linear(duration: 1).repeatForever(autoreverses: false)) {
                    rotation = 360
                }
            }
    }
}

#Preview {
    Color.clear
        .sheet(isPresented: .constant(true)) {
            PrivacySheetView()
                .environment(AppTheme())
                .environment(AppState())
                .environment(NavigationState())
        }
}
