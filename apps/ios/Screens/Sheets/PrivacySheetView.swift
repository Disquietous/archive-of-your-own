import SwiftUI

struct PrivacySheetView: View {
    @Environment(AppTheme.self) private var theme
    @Environment(AppState.self) private var state
    @Environment(NavigationState.self) private var nav
    @Environment(\.dismiss) private var dismiss

    @State private var circuitTask: Task<Void, Never>?
    @State private var showDisconnectConfirm = false
    @State private var requestingNewNodes = false

    private var isInProgress: Bool {
        state.bridge.torStatus == .connecting || state.isTestingCircuit || state.isResolvingCloudflare
    }

    private var isPrivate: Bool {
        state.bridge.torStatus.isConnected && !isInProgress
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
                    // Signed-in identity (accounts are managed in Settings)
                    accountRow

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
        .alert("Disconnect from Tor?", isPresented: $showDisconnectConfirm) {
            Button("Disconnect", role: .destructive) {
                Task { await state.bridge.disconnectTor() }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("""
                Your connection will no longer be routed through Tor. Your IP address will be visible to AO3 and your \
                network provider will be able to see that you are accessing AO3.
                """)
        }
    }

    // MARK: - Account

    /// Who requests go out as. Switching, adding and signing out live in
    /// Settings › AO3 Accounts; this row only shows the identity and links
    /// there.
    private var accountRow: some View {
        HStack(spacing: 12) {
            HStack(spacing: 6) {
                Image(systemName: "person.crop.circle")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(theme.ink2)
                Text(state.ao3Username ?? "Not signed in")
                    .font(.custom("HankenGrotesk", size: 14).weight(.semibold))
                    .foregroundStyle(theme.ink)
                    .lineLimit(1)
            }
            Spacer()
            Button {
                dismiss()
                nav.selectedTab = .settings
                nav.settingsPath = NavigationPath([AppDestination.accountManagement])
            } label: {
                Text("Accounts")
                    .font(.custom("HankenGrotesk", size: 14).weight(.semibold))
                    .foregroundStyle(theme.accent)
            }
        }
        .padding(.horizontal, 14)
        .frame(height: 40)
        .background(theme.surface2)
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .padding(.horizontal, theme.pad)
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

                if isPrivate, !state.bridge.circuitHops.isEmpty {
                    hopChips
                } else {
                    Text(statusSubtitle)
                        .font(Typography.uiSmall())
                        .foregroundStyle(theme.ink3)
                }

                newNodesShield
            }
            .padding(.horizontal, theme.pad)

            TorCircuitView(showsPathNote: true)
                .padding(.horizontal, theme.pad + 8)
        }
    }

    /// The live path as one chip per node: role icon plus the relay's
    /// country code ("--" when GeoIP has no entry — never invented).
    private var hopChips: some View {
        HStack(spacing: 4) {
            ForEach(Array(state.bridge.circuitHops.enumerated()), id: \.offset) { _, hop in
                HStack(spacing: 3) {
                    Image(systemName: Self.roleIcon(hop.role))
                        .font(.system(size: 8, weight: .semibold))
                    Text(hop.country.isEmpty ? "--" : hop.country.uppercased())
                        .font(.custom("HankenGrotesk", size: 10).weight(.bold))
                        .kerning(0.3)
                }
                .foregroundStyle(theme.ink2)
                .padding(.horizontal, 5)
                .padding(.vertical, 2)
                .background(theme.ink.opacity(0.08))
                .clipShape(RoundedRectangle(cornerRadius: 4))
            }
        }
    }

    /// The shield stands for the connection mode: sage = Private (routed
    /// through relays), red = Public (direct). When private, tapping asks
    /// for a fresh set of relay nodes without a full reconnect; when
    /// public, it connects.
    @ViewBuilder
    private var newNodesShield: some View {
        if isInProgress || requestingNewNodes {
            ProgressView()
                .controlSize(.small)
                .tint(theme.sage)
                .frame(width: 30, height: 30)
        } else {
            Button {
                if isPrivate {
                    requestingNewNodes = true
                    Task { @MainActor in
                        _ = await state.newCircuitNow()
                        state.bridge.refreshCircuitHops()
                        requestingNewNodes = false
                    }
                } else {
                    Task { await state.connectTorNow() }
                }
            } label: {
                Image(systemName: isPrivate ? "checkmark.shield" : "xmark.shield")
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(isPrivate ? theme.sage : Color(hex: "CE514D"))
                    .frame(width: 30, height: 30)
                    .background((isPrivate ? theme.sage : Color(hex: "CE514D")).opacity(0.12))
                    .clipShape(Circle())
            }
            .buttonStyle(IconButtonPressStyle())
            .accessibilityLabel(isPrivate ? "Request new relay nodes" : "Connect via Tor")
        }
    }

    private static func roleIcon(_ role: String) -> String {
        switch role {
        case "Guard": "shield.lefthalf.filled"
        case "Exit": "arrow.up.forward"
        default: "arrow.triangle.swap"
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
                    Task { await state.connectTorNow() }
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
                    circuitTask = Task { await state.connectTorNow() }
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

                Button {
                    showDisconnectConfirm = true
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "shield.slash")
                            .font(.system(size: 13, weight: .semibold))
                        Text("Disconnect")
                            .font(Typography.smallButtonLabel())
                    }
                    .foregroundStyle(Color(hex: "CE514D"))
                    .frame(maxWidth: .infinity)
                    .frame(height: 40)
                }
                .buttonStyle(ButtonPressStyle())
            }
        }
        .padding(.horizontal, theme.pad)
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

#Preview {
    Color.clear
        .sheet(isPresented: .constant(true)) {
            PrivacySheetView()
                .environment(AppTheme())
                .environment(AppState())
                .environment(NavigationState())
        }
}
