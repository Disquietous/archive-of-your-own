import SwiftUI

/// The app-state hub, anchored to the sidebar's footer pill. Everything about
/// the app's *current* state lives here: the Tor connection (with circuit
/// controls) and the AO3 identity (with inline sign-in) — state first,
/// persistence second. Account roster admin stays in Settings.
struct PrivacyPopoverView: View {
    @Bindable var theme: AppTheme
    @Bindable var appState: AppState
    @Bindable var model: MacAppModel

    @State private var username = ""
    @State private var password = ""
    @State private var isSigningIn = false
    @State private var loginError: String?

    private struct Hop: Identifiable {
        let label: String, icon: String, tint: KeyPath<AppTheme, Color>
        var id: String { label }
    }

    private let hops = [
        Hop(label: "You", icon: "book", tint: \.ink2),
        Hop(label: "Guard", icon: "shield", tint: \.sage),
        Hop(label: "Relay", icon: "globe", tint: \.sage),
        Hop(label: "Exit", icon: "circle.circle", tint: \.accent),
        Hop(label: "AO3", icon: "building.columns", tint: \.ink2),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            connectionSection
            divider.padding(.vertical, 12)
            accountSection
            divider.padding(.vertical, 12)
            togglesSection
        }
        .padding(16)
        .frame(width: 310)
        .background(theme.surface)
    }

    private var divider: some View {
        theme.line.frame(height: 1)
    }

    // MARK: - Connection

    private var connectionSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                Circle()
                    .fill(theme.sage.opacity(0.15))
                    .frame(width: 34, height: 34)
                    .overlay {
                        Image(systemName: connected ? "checkmark.shield" : "shield")
                            .font(.system(size: 15, weight: .medium))
                            .foregroundStyle(connected ? theme.sage : theme.ink3)
                    }
                VStack(alignment: .leading, spacing: 1) {
                    Text(connected ? "Connected through Tor" : "Not connected")
                        .font(Font(MacFont.ui(14, weight: .bold)))
                        .foregroundStyle(theme.ink)
                    Text(connectionSubtitle)
                        .font(Font(MacFont.ui(11.5)))
                        .foregroundStyle(theme.ink3)
                }
            }
            .padding(.bottom, connected ? 0 : 10)

            if connected {
                HStack(spacing: 0) {
                    ForEach(Array(hops.enumerated()), id: \.element.id) { index, hop in
                        VStack(spacing: 5) {
                            Circle()
                                .fill(theme[keyPath: hop.tint].opacity(0.16))
                                .frame(width: 28, height: 28)
                                .overlay {
                                    Image(systemName: hop.icon)
                                        .font(.system(size: 11, weight: .medium))
                                        .foregroundStyle(theme[keyPath: hop.tint])
                                }
                            Text(hop.label)
                                .font(Font(MacFont.ui(10, weight: .semibold)))
                                .foregroundStyle(theme.ink3)
                        }
                        .frame(maxWidth: .infinity)
                        if index < hops.count - 1 {
                            theme.line2.frame(width: 16, height: 2).offset(y: -8)
                        }
                    }
                }
                .padding(.vertical, 10)
            }

            Button {
                Task { await appState.connectTor() }
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 12, weight: .semibold))
                    Text(connected ? "New circuit" : "Connect")
                        .font(Font(MacFont.ui(13, weight: .bold)))
                }
                .foregroundStyle(theme.ink)
                .frame(maxWidth: .infinity, minHeight: 34)
                .background(theme.surface)
                .clipShape(RoundedRectangle(cornerRadius: 9))
                .overlay(RoundedRectangle(cornerRadius: 9).stroke(theme.line, lineWidth: 1))
            }
            .buttonStyle(.plain)
        }
    }

    private var connectionSubtitle: String {
        if connected { return "3-hop circuit · new identity available" }
        if appState.isTestingCircuit { return "Testing circuit \(appState.circuitAttempt)…" }
        if appState.isResolvingCloudflare { return "Resolving challenge…" }
        return appState.torStatus.displayText
    }

    // MARK: - Account (identity is current state)

    @ViewBuilder
    private var accountSection: some View {
        if appState.needsReauth {
            reauthForm
        } else if let account = appState.ao3Username {
            signedInRow(account)
        } else {
            signInForm
        }
    }

    private func signedInRow(_ account: String) -> some View {
        HStack(spacing: 10) {
            Circle()
                .fill(theme.accent2)
                .frame(width: 34, height: 34)
                .overlay {
                    Text(String(account.prefix(1)).uppercased())
                        .font(Font(MacFont.serif(16, weight: .semibold)))
                        .foregroundStyle(theme.onAccent)
                }
            VStack(alignment: .leading, spacing: 1) {
                Text(account)
                    .font(Font(MacFont.ui(13.5, weight: .bold)))
                    .foregroundStyle(theme.ink)
                Text("Signed in to AO3")
                    .font(Font(MacFont.ui(11)))
                    .foregroundStyle(theme.ink3)
            }
            Spacer()
            if appState.ao3AccountCount > 1 {
                Menu {
                    ForEach(appState.bridge.getAccounts(), id: \.id) { other in
                        if !other.isActive {
                            Button("Switch to \(other.username)") {
                                appState.switchAccount(other.id)
                            }
                        }
                    }
                } label: {
                    Image(systemName: "arrow.triangle.2.circlepath")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(theme.ink2)
                }
                .menuStyle(.borderlessButton)
                .frame(width: 24)
                .help("Switch account")
            }
            Button("Log Out") {
                Task { @MainActor in
                    await appState.bridge.logoutAccount()
                    appState.refreshAO3Username()
                }
            }
            .buttonStyle(.plain)
            .font(Font(MacFont.ui(11.5, weight: .bold)))
            .foregroundStyle(Color(hex: "CE514D"))
        }
    }

    private var signInForm: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("AO3 ACCOUNT")
                .font(Font(MacFont.ui(10.5, weight: .bold)))
                .kerning(0.6)
                .foregroundStyle(theme.ink3)
            if appState.bridge.networkBlocked {
                Text("Connect to Tor to sign in.")
                    .font(Font(MacFont.ui(12)))
                    .foregroundStyle(theme.ink3)
            } else {
                TextField("Username", text: $username)
                    .textFieldStyle(.roundedBorder)
                SecureField("Password", text: $password)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { signIn() }
                if let loginError {
                    Text(loginError)
                        .font(Font(MacFont.ui(11.5, weight: .medium)))
                        .foregroundStyle(Color(hex: "CE514D"))
                }
                signInButton(label: "Sign In") { signIn() }
                Text("Used once to sign in — never stored. Enables subscriptions, inbox, kudos, and bookmark sync.")
                    .font(Font(MacFont.ui(10.5)))
                    .foregroundStyle(theme.ink3)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var reauthForm: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "person.badge.clock")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(theme.accent2)
                Text("Session expired — \(appState.ao3Username ?? "account")")
                    .font(Font(MacFont.ui(12.5, weight: .bold)))
                    .foregroundStyle(theme.ink)
            }
            if appState.bridge.networkBlocked {
                // Same invariant as sign-in: with Tor required, credentials
                // never travel before a circuit is up.
                Text("Connect to Tor above to sign back in.")
                    .font(Font(MacFont.ui(12)))
                    .foregroundStyle(theme.ink3)
            } else {
                SecureField("Password", text: $password)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { reauth() }
                if let loginError {
                    Text(loginError)
                        .font(Font(MacFont.ui(11.5, weight: .medium)))
                        .foregroundStyle(Color(hex: "CE514D"))
                }
                signInButton(label: "Sign Back In") { reauth() }
            }
        }
    }

    private func signInButton(label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Group {
                if isSigningIn {
                    ProgressView().controlSize(.small)
                } else {
                    Text(label)
                        .font(Font(MacFont.ui(12.5, weight: .bold)))
                }
            }
            .foregroundStyle(theme.onAccent)
            .frame(maxWidth: .infinity, minHeight: 32)
            .background(theme.accent)
            .clipShape(RoundedRectangle(cornerRadius: 9))
        }
        .buttonStyle(.plain)
        .disabled(isSigningIn || password.isEmpty)
    }

    // MARK: - Toggles

    private var togglesSection: some View {
        VStack(spacing: 0) {
            toggleRow("Hide explicit content", isOn: $model.hideExplicit)
            divider
            toggleRow("New circuit on launch", isOn: $theme.useTorByDefault)
        }
    }

    private func toggleRow(_ label: String, isOn: Binding<Bool>) -> some View {
        HStack(spacing: 12) {
            Text(label)
                .font(Font(MacFont.ui(13, weight: .medium)))
                .foregroundStyle(theme.ink)
            Spacer()
            Toggle("", isOn: isOn)
                .labelsHidden()
                .toggleStyle(.switch)
                .tint(theme.sage)
        }
        .padding(.vertical, 9)
    }

    // MARK: - Actions

    private func signIn() {
        // Belt-and-braces alongside the UI gate: with Tor required,
        // credentials never leave except over a circuit.
        guard !isSigningIn, !username.isEmpty, !password.isEmpty, !appState.bridge.networkBlocked else { return }
        isSigningIn = true
        loginError = nil
        Task { @MainActor in
            do {
                let success = try await appState.bridge.login(username: username, password: password)
                if success {
                    try? appState.bridge.saveAccount(username: username)
                    appState.bridge.saveSessionCookies()
                    appState.refreshAO3Username()
                    username = ""
                    password = ""
                    await appState.loadSubscriptions(force: true)
                } else {
                    loginError = "Login failed. Check your credentials."
                }
            } catch {
                loginError = "\(error)".contains("timeout")
                    ? "Timed out. Try a new circuit above." : error.localizedDescription
            }
            isSigningIn = false
        }
    }

    private func reauth() {
        guard !isSigningIn, !password.isEmpty, !appState.bridge.networkBlocked else { return }
        isSigningIn = true
        loginError = nil
        Task { @MainActor in
            do {
                let success = try await appState.bridge.reauthenticate(password: password)
                if success {
                    appState.needsReauth = false
                    password = ""
                } else {
                    loginError = "Login failed. Check your password."
                }
            } catch {
                loginError = error.localizedDescription
            }
            isSigningIn = false
        }
    }

    private var connected: Bool {
        appState.torStatus.isConnected
    }
}
