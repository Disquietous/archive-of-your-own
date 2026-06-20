import SwiftUI

struct NetworkLoadingView: View {
    @Environment(AppTheme.self) private var theme
    @Environment(AppState.self) private var state

    let message: String
    var task: NetworkTask?
    var operation: String = ""
    var onCancel: (() -> Void)?

    @State private var progressText: String?
    @State private var countdownText: String?
    @State private var timer: Timer?
    @State private var phaseStart = Date()
    @State private var lastStatus: String = ""

    private var isReconnecting: Bool {
        task?.isReconnecting == true
    }

    var body: some View {
        VStack(spacing: 16) {
            if isReconnecting {
                reconnectingView
            } else {
                normalView
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 60)
        .onAppear { startPolling() }
        .onDisappear { stopPolling() }
        .onChange(of: isReconnecting) { _, reconnecting in
            if !reconnecting {
                phaseStart = Date()
                lastStatus = ""
                progressText = nil
                countdownText = nil
            }
        }
    }

    private var reconnectingView: some View {
        VStack(spacing: 12) {
            TorCircuitView()
                .padding(.horizontal, 32)

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
                    Text("Testing circuit… (\(state.circuitAttempt)/5)")
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
            } else {
                HStack(spacing: 8) {
                    ProgressView().tint(theme.sage)
                    Text("Reconnecting…")
                        .font(Typography.uiSmall())
                        .foregroundStyle(theme.ink3)
                }
            }

            if let onCancel {
                Button("Cancel") {
                    state.bridge.cancelRequest()
                    onCancel()
                }
                    .font(Typography.smallButtonLabel())
                    .foregroundStyle(theme.accent)
            }
        }
    }

    private var normalView: some View {
        VStack(spacing: 16) {
            ProgressView()
                .tint(theme.accent)

            Text(task?.statusMessage ?? message)
                .font(Typography.uiBody())
                .foregroundStyle(theme.ink3)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)

            if progressText != nil || countdownText != nil {
                VStack(spacing: 4) {
                    if let progressText {
                        Text(progressText)
                            .font(.custom("HankenGrotesk", size: 12).weight(.medium))
                            .foregroundStyle(theme.ink3)
                            .monospacedDigit()
                    }
                    if let countdownText {
                        Text(countdownText)
                            .font(.custom("HankenGrotesk", size: 11).weight(.medium))
                            .foregroundStyle(theme.ink3.opacity(0.7))
                            .monospacedDigit()
                    }
                }
            }

            if let onCancel {
                Button("Cancel") {
                    state.bridge.cancelRequest()
                    onCancel()
                }
                    .font(Typography.smallButtonLabel())
                    .foregroundStyle(theme.accent)
            }
        }
    }

    private func startPolling() {
        phaseStart = Date()
        timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { _ in
            guard !isReconnecting else {
                progressText = nil
                countdownText = nil
                return
            }
            updateProgress()
            updateCountdown()
        }
    }

    private func stopPolling() {
        timer?.invalidate()
        timer = nil
    }

    private func updateProgress() {
        guard !operation.isEmpty, let progress = state.bridge.getFetchProgress(operation: operation) else { return }

        if progress.status != lastStatus {
            lastStatus = progress.status
            phaseStart = Date()
        }

        switch progress.status {
        case "connecting":
            progressText = "Connecting..."
        case "downloading":
            let received = formatBytes(progress.bytesReceived)
            if progress.totalBytes > 0 {
                let total = formatBytes(UInt64(progress.totalBytes))
                progressText = "Downloading \(received) / \(total)"
            } else if progress.bytesReceived > 0 {
                progressText = "Downloading \(received)"
            } else {
                progressText = "Downloading..."
            }
        case "complete":
            if progress.bytesReceived > 0 {
                progressText = "Downloaded \(formatBytes(progress.bytesReceived))"
            }
            countdownText = nil
        default:
            break
        }
    }

    private func updateCountdown() {
        let timeout = Int(state.bridge.getRequestTimeout())
        let elapsed = Int(Date().timeIntervalSince(phaseStart))
        let remaining = max(0, timeout - elapsed)

        if remaining > 0 && lastStatus != "complete" {
            countdownText = "Timeout in \(remaining)s"
        } else {
            countdownText = nil
        }
    }

    private func formatBytes(_ bytes: UInt64) -> String {
        if bytes < 1024 { return "\(bytes) B" }
        if bytes < 1024 * 1024 { return String(format: "%.1f KB", Double(bytes) / 1024) }
        return String(format: "%.1f MB", Double(bytes) / (1024 * 1024))
    }
}

struct NetworkErrorView: View {
    @Environment(AppTheme.self) private var theme

    let message: String
    var onRetry: (() -> Void)?
    var onGoBack: (() -> Void)?

    var body: some View {
        VStack(spacing: 12) {
            Text(message)
                .font(Typography.uiBody())
                .foregroundStyle(theme.ink3)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity)

            if let onRetry {
                Button("Retry", action: onRetry)
                    .font(Typography.smallButtonLabel())
                    .foregroundStyle(theme.accent)
            }

            if let onGoBack {
                Button("Go back", action: onGoBack)
                    .font(Typography.smallButtonLabel())
                    .foregroundStyle(theme.ink3)
            }
        }
        .padding(.top, 40)
    }
}
