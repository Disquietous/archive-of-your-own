import SwiftUI

struct TorConnectOverlayView: View {
    @Bindable var theme: AppTheme
    let appState: AppState

    var body: some View {
        ZStack {
            theme.bg.opacity(0.92)

            VStack(spacing: 20) {
                if appState.torConnectFailed {
                    Image(systemName: "wifi.exclamationmark")
                        .font(.system(size: 36, weight: .light))
                        .foregroundStyle(theme.accent2)

                    Text("Connection Failed")
                        .font(Font(MacFont.serif(22, weight: .semibold)))
                        .foregroundStyle(theme.ink)

                    Text(failureDetail)
                        .font(Font(MacFont.ui(13)))
                        .foregroundStyle(theme.ink3)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 320)

                    HStack(spacing: 12) {
                        GateButton(theme: theme, label: "Retry", fill: theme.sage) {
                            Task {
                                appState.torConnectFailed = false
                                await appState.connectTor()
                                if appState.torStatus.isConnected {
                                    appState.showTorConnectOverlay = false
                                }
                            }
                        }
                        .frame(width: 120)

                        GateButton(theme: theme, label: "Cancel", fill: theme.surface3) {
                            appState.cancelTorConnect()
                            appState.showTorConnectOverlay = false
                        }
                        .frame(width: 120)
                    }
                } else {
                    ProgressView()
                        .controlSize(.large)

                    Text("Connecting to Tor")
                        .font(Font(MacFont.serif(22, weight: .semibold)))
                        .foregroundStyle(theme.ink)

                    Text(progressDetail)
                        .font(Font(MacFont.ui(13)))
                        .foregroundStyle(theme.ink3)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 320)

                    Button("Cancel") {
                        appState.cancelTorConnect()
                        appState.showTorConnectOverlay = false
                    }
                    .buttonStyle(.plain)
                    .font(Font(MacFont.ui(12.5, weight: .semibold)))
                    .foregroundStyle(theme.ink3)
                    .padding(.top, 4)
                }
            }
            .padding(40)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var progressDetail: String {
        if appState.isResolvingCloudflare { return "Resolving archive challenge…" }
        if appState.isTestingCircuit { return "Testing circuit \(appState.circuitAttempt)…" }
        switch appState.torStatus {
        case .connecting: return "Establishing Tor circuit…"
        case .connected: return "Circuit established"
        default: return "Initializing…"
        }
    }

    private var failureDetail: String {
        if case .error(let msg) = appState.torStatus {
            return msg
        }
        return "Could not connect to the Tor network. Check your internet connection and try again."
    }
}
