import SwiftUI

struct NetworkLoadingView: View {
    @Environment(AppTheme.self) private var theme
    @Environment(AppState.self) private var state

    let message: String
    var task: NetworkTask?
    var operation: String = ""
    var onCancel: (() -> Void)?

    private var recovery: AppState.RecoveryStatus? {
        state.currentRecovery
    }

    var body: some View {
        VStack(spacing: 16) {
            if let recovery {
                reconnectingView(recovery)
            } else if state.showTorConnectOverlay || state.isTestingCircuit || state.isResolvingCloudflare {
                connectFlowView
            } else {
                normalView
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 60)
    }

    /// The recovery engine is actively rotating/backing off mid-request.
    /// Names the remedy honestly instead of a generic "reconnecting" —
    /// this is what the old poll-and-mute NetworkLoadingView never showed.
    private func reconnectingView(_ recovery: AppState.RecoveryStatus) -> some View {
        VStack(spacing: 12) {
            TorCircuitView()
                .padding(.horizontal, 32)

            HStack(spacing: 8) {
                ProgressView().tint(theme.sage)
                Text(recoveryMessage(recovery))
                    .font(Typography.uiSmall())
                    .foregroundStyle(theme.ink3)
                    .multilineTextAlignment(.center)
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

    /// The initial connect flow (bootstrap/circuit-test/Cloudflare) — driven
    /// by AppState+Tor.swift, not the recovery engine.
    private var connectFlowView: some View {
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

            Text(message)
                .font(Typography.uiBody())
                .foregroundStyle(theme.ink3)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)

            if let progressText {
                Text(progressText)
                    .font(.custom("HankenGrotesk", size: 12).weight(.medium))
                    .foregroundStyle(theme.ink3)
                    .monospacedDigit()
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

    /// The last progress event reported for this specific screen's fetch —
    /// `operation` mirrors the `OpKind::Fetch` label the engine tags each
    /// listing/content fetch with, so a screen only shows its own progress.
    private var progressText: String? {
        guard !operation.isEmpty, let progress = state.currentProgress,
              case .fetch(let label) = progress.kind, label == operation else { return nil }
        switch progress.phase {
        case .connecting:
            return "Connecting…"
        case .downloading:
            let received = formatBytes(progress.bytes)
            if let total = progress.total, total > 0 {
                return "Downloading \(received) / \(formatBytes(total))"
            } else if progress.bytes > 0 {
                return "Downloading \(received)"
            }
            return "Downloading…"
        case .complete:
            return progress.bytes > 0 ? "Downloaded \(formatBytes(progress.bytes))" : nil
        case .failed:
            return nil
        }
    }

    private func formatBytes(_ bytes: UInt64) -> String {
        if bytes < 1024 { return "\(bytes) B" }
        if bytes < 1024 * 1024 { return String(format: "%.1f KB", Double(bytes) / 1024) }
        return String(format: "%.1f MB", Double(bytes) / (1024 * 1024))
    }

    /// Names the remedy honestly instead of a generic "reconnecting…" —
    /// e.g. "Archive connection failed. Trying a new route… (2 of 3)".
    private func recoveryMessage(_ recovery: AppState.RecoveryStatus) -> String {
        let attempt = "(\(recovery.attempt) of \(recovery.maxAttempts))"
        switch recovery.step {
        case .earningClearance:
            return "Passing the archive's connection check… \(attempt)"
        case .backingOff(let seconds):
            return "The archive is temporarily unavailable. Waiting \(seconds)s… \(attempt)"
        case .reconnecting:
            return "Rebuilding the Tor connection… \(attempt)"
        case .rotatingCircuit, .retrying, nil:
            break
        }
        switch recovery.remedy {
        case .rotate, .rotateAndReclear:
            return "Archive connection failed. Trying a new route… \(attempt)"
        case .backoff:
            return "The archive is temporarily unavailable. Retrying… \(attempt)"
        case .reconnect:
            return "Rebuilding the Tor connection… \(attempt)"
        case .purge:
            return "Session expired. Please sign in again."
        }
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
