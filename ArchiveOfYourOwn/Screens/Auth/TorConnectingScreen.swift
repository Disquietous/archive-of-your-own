import SwiftUI

struct TorConnectingScreen: View {
    @Environment(AppTheme.self) private var theme: AppTheme
    @Environment(AppState.self) private var state

    @State private var showDisableTorConfirm = false

    private var isSearching: Bool {
        state.bridge.torStatus == .connecting || state.isTestingCircuit || state.isResolvingCloudflare
    }

    var body: some View {
        VStack(spacing: 0) {
            Spacer()

            Image(systemName: state.torConnectFailed ? "exclamationmark.shield" : "shield.checkmark")
                .font(.system(size: 44, weight: .medium))
                .foregroundStyle(state.torConnectFailed ? theme.accent2 : theme.sage)
                .padding(.bottom, 16)

            Text(state.torConnectFailed ? "Could not find a working circuit" : "Connecting to Tor")
                .font(Typography.pageTitle())
                .foregroundStyle(theme.ink)
                .padding(.bottom, 6)

            Text(statusSubtitle)
                .font(.custom("HankenGrotesk", size: 14).weight(.medium))
                .foregroundStyle(theme.ink3)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
                .padding(.bottom, 28)

            TorCircuitView()
                .padding(.horizontal, 32)

            if isSearching {
                statusIndicator
                    .padding(.top, 16)
            }

            Spacer()

            buttons
                .padding(.horizontal, 32)
                .padding(.bottom, 40)
        }
        .background(theme.bg)
        .task {
            if !state.bridge.torStatus.isConnected && !state.torConnectFailed {
                await state.connectTor()
            }
        }
        .alert("Disable Tor?", isPresented: $showDisableTorConfirm) {
            Button("Disable Tor", role: .destructive) {
                theme.useTorByDefault = false
                state.bridge.cloudflareReady = true
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Your connection will no longer be routed through Tor. Your traffic to AO3 will be visible to your network provider and will reveal your IP address to AO3 and Cloudflare.")
        }
    }

    private var statusSubtitle: String {
        if state.torConnectFailed && state.torConnectCancelled {
            return "Search was cancelled after \(state.circuitAttempt) attempts."
        } else if state.torConnectFailed {
            return "Tor could not establish a connection."
        } else {
            return "Testing exit nodes until a working circuit is found…"
        }
    }

    @ViewBuilder
    private var statusIndicator: some View {
        if state.bridge.torStatus == .connecting {
            HStack(spacing: 8) {
                ProgressView().tint(theme.sage)
                Text("Bootstrapping Tor…")
                    .font(Typography.uiSmall())
                    .foregroundStyle(theme.ink3)
            }
        } else if state.isTestingCircuit {
            HStack(spacing: 8) {
                ProgressView().tint(theme.sage)
                Text("Testing circuit… (attempt \(state.circuitAttempt))")
                    .font(Typography.uiSmall())
                    .foregroundStyle(theme.ink3)
            }
        } else if state.isResolvingCloudflare {
            HStack(spacing: 8) {
                ProgressView().tint(theme.sage)
                Text("Passing Cloudflare check…")
                    .font(Typography.uiSmall())
                    .foregroundStyle(theme.ink3)
            }
        }
    }

    @ViewBuilder
    private var buttons: some View {
        if state.torConnectFailed {
            VStack(spacing: 12) {
                Button {
                    Task { await state.connectTor() }
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "arrow.clockwise")
                            .font(.system(size: 14, weight: .semibold))
                        Text("Try again")
                            .font(Typography.buttonLabel())
                    }
                    .foregroundStyle(theme.onAccent)
                    .frame(maxWidth: .infinity)
                    .frame(height: 46)
                    .background(RoundedRectangle(cornerRadius: Radius.button).fill(theme.sage))
                }
                .buttonStyle(ButtonPressStyle())

                Button {
                    showDisableTorConfirm = true
                } label: {
                    Text("Disable Tor and continue without privacy")
                        .font(Typography.smallButtonLabel())
                        .foregroundStyle(theme.ink3)
                        .frame(maxWidth: .infinity)
                        .frame(height: 40)
                }
            }
        } else if isSearching {
            VStack(spacing: 12) {
                if state.circuitAttempt >= 5 {
                    Button {
                        Task { await state.proceedWithCurrentCircuit() }
                    } label: {
                        Text("Proceed with current circuit")
                            .font(Typography.smallButtonLabel())
                            .foregroundStyle(theme.accent)
                            .frame(maxWidth: .infinity)
                            .frame(height: 40)
                    }
                }

                Button {
                    state.cancelTorConnect()
                } label: {
                    Text("Stop searching")
                        .font(Typography.smallButtonLabel())
                        .foregroundStyle(theme.ink3)
                        .frame(maxWidth: .infinity)
                        .frame(height: 40)
                }
            }
        }
    }
}
