import SwiftUI

/// Settings › Privacy › Privacy mode: how requests are protected (Tor, the
/// user's own VPN, or nothing), the trust statement for each, and the VPN
/// registration card. Mirrors the macOS Privacy pane.
struct PrivacyModeScreen: View {
    @Environment(AppTheme.self) private var theme
    @Environment(AppState.self) private var state

    @State private var confirmOpen = false
    @State private var confirmVpnOptional = false
    @State private var vpnLabel = "NordVPN"
    @State private var vpnError: String?

    var body: some View {
        ZStack(alignment: .top) {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    group("Protection") {
                        SegmentedControlView(selection: modeBinding,
                                             items: PrivacyModeSetting.allCases.map { (key: $0, label: $0.title) })
                        caption(modeCaption)
                    }

                    switch theme.privacyMode {
                    case .tor: torGroup
                    case .vpn: vpnGroup
                    case .open: EmptyView()
                    }
                }
                .padding(.horizontal, theme.pad)
                .padding(.bottom, 32)
            }
            .contentMargins(.top, ScreenChromeMetrics.height, for: .scrollContent)
            .scrollDismissesKeyboard(.interactively)

            ScreenChrome(title: "Privacy Mode")
        }
        .libraryScreen()
        .alert("Turn off protection?", isPresented: $confirmOpen) {
            Button("Turn Off", role: .destructive) { applyMode(.open) }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("AO3, its edge network, and whoever runs your network will see your address directly. Everything stored on this device stays encrypted.")
        }
        .alert("Send without the VPN?", isPresented: $confirmVpnOptional) {
            Button("Allow", role: .destructive) { theme.vpnRequired = false }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Requests will go out even when your VPN is off or unrecognised. The status is still shown, but nothing is blocked.")
        }
    }

    // MARK: - Mode

    private var modeBinding: Binding<PrivacyModeSetting> {
        Binding(get: { theme.privacyMode }, set: { selectMode($0) })
    }

    /// The trust statement for each mode: what protects you and who you
    /// are trusting. Deliberately even-handed between Tor and a VPN.
    private var modeCaption: String {
        switch theme.privacyMode {
        case .tor:
            return "Your traffic passes through three relays run by volunteers. No single relay sees both who you are and what you read, but the relays are run by strangers: the first sees your address, the last sees that someone is reading AO3. Slower, and AO3’s edge sometimes challenges it."
        case .vpn:
            return "All your traffic goes through one company you pay. It sees your address and that you read AO3; the protection is its no-logs promise and audits. Fast, and rarely challenged. This app checks the VPN before every request; your VPN app’s own kill switch covers the moment it drops."
        case .open:
            return "AO3, its edge network, and whoever runs your network see your address directly. Everything stored on this device is still encrypted."
        }
    }

    private func selectMode(_ mode: PrivacyModeSetting) {
        guard mode != theme.privacyMode else { return }
        if mode == .open {
            confirmOpen = true
        } else {
            applyMode(mode)
        }
    }

    /// Leaving Tor mode drops the Tor transport, so requests in the new
    /// mode really do go out directly rather than riding the old circuit.
    private func applyMode(_ mode: PrivacyModeSetting) {
        let leavingTor = theme.privacyMode == .tor && mode != .tor
        theme.privacyMode = mode
        vpnError = nil
        if leavingTor && state.bridge.torStatus.isConnected {
            Task { await state.bridge.disconnectTor() }
        }
        if mode == .vpn {
            state.bridge.refreshVpnStatus()
        }
    }

    // MARK: - Tor

    private var torGroup: some View {
        group("Tor") {
            row("Status", value: state.bridge.torStatus.displayText)
            outlineButton(state.bridge.torStatus.isConnected ? "New Identity" : "Connect",
                          icon: "arrow.triangle.2.circlepath") {
                Task { await state.connectTorNow() }
            }
        }
    }

    // MARK: - VPN

    private var vpnGroup: some View {
        let status = state.bridge.privacyStatus
        let fingerprint = state.bridge.vpnFingerprint
        return group("My VPN") {
            if let fingerprint {
                row("Registered", value: "\(fingerprint.label) · \(fingerprint.tunnelKind) tunnel")
                Divider().foregroundStyle(theme.line)
                row("Status", value: status.titleWithCheck(at: state.bridge.vpnCheckedAt))
                Divider().foregroundStyle(theme.line)
                Toggle("Block requests when my VPN is off", isOn: vpnRequiredBinding)
                    .font(Typography.uiBody())
                    .foregroundStyle(theme.ink)
                caption("Off: requests go out anyway; the status is still shown.")
                Divider().foregroundStyle(theme.line)
                HStack(spacing: 8) {
                    outlineButton("Check Now", icon: "arrow.clockwise") {
                        state.bridge.refreshVpnStatus()
                    }
                    outlineButton("Update", icon: "arrow.up.doc") {
                        registerVPN(label: fingerprint.label)
                    }
                }
                Button {
                    state.bridge.forgetVPN()
                    vpnError = nil
                } label: {
                    Text("Forget this VPN")
                        .font(Typography.smallButtonLabel())
                        .foregroundStyle(Color(hex: "CE514D"))
                        .frame(maxWidth: .infinity)
                        .frame(height: 40)
                }
                .buttonStyle(ButtonPressStyle())
            } else {
                HStack(spacing: 8) {
                    Text("Name")
                        .font(Typography.uiBody())
                        .foregroundStyle(theme.ink)
                    Spacer()
                    TextField("NordVPN", text: $vpnLabel)
                        .textFieldStyle(.plain)
                        .multilineTextAlignment(.trailing)
                        .font(Typography.uiBody())
                        .foregroundStyle(theme.ink)
                }
                outlineButton("Register Current VPN", icon: "checkmark.shield") {
                    registerVPN(label: vpnLabel)
                }
            }
            if let vpnError {
                Text(vpnError)
                    .font(Typography.uiCaption())
                    .foregroundStyle(Color(hex: "CE514D"))
                    .fixedSize(horizontal: false, vertical: true)
            }
            caption(fingerprint == nil
                    ? "Connect the VPN first, then register it. The app remembers how the tunnel looks (its resolvers and address range), never the interface name, and checks for it before every request."
                    : status.subtitle)
        }
    }

    /// Switching the block off is confirmed; switching it on is immediate.
    private var vpnRequiredBinding: Binding<Bool> {
        Binding(
            get: { theme.vpnRequired },
            set: { on in
                if on { theme.vpnRequired = true } else { confirmVpnOptional = true }
            }
        )
    }

    private func registerVPN(label: String) {
        do {
            _ = try state.bridge.registerVPN(label: label)
            vpnError = nil
        } catch {
            vpnError = AppState.readableError(error)
        }
    }

    // MARK: - Pieces

    private func group<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title.uppercased())
                .font(Typography.sectionHeader())
                .tracking(0.08 * 13)
                .foregroundStyle(theme.ink3)
            VStack(alignment: .leading, spacing: 12) {
                content()
            }
            .padding(.horizontal, theme.cardPad)
            .padding(.vertical, theme.cardPad + 4)
            .background(
                RoundedRectangle(cornerRadius: Radius.settingsGroup)
                    .fill(theme.surface)
            )
        }
    }

    private func caption(_ text: String) -> some View {
        Text(text)
            .font(Typography.uiCaption())
            .foregroundStyle(theme.ink3)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func row(_ label: String, value: String) -> some View {
        HStack(spacing: 8) {
            Text(label)
                .font(Typography.uiBody())
                .foregroundStyle(theme.ink)
            Spacer()
            Text(value)
                .font(Typography.uiSmall())
                .foregroundStyle(theme.ink3)
                .multilineTextAlignment(.trailing)
        }
    }

    private func outlineButton(_ label: String, icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: icon)
                    .font(.system(size: 13, weight: .semibold))
                Text(label)
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
