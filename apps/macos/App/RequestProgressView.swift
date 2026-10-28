import Combine
import SwiftUI

/// Floating banner shown over a pane's content area while a user-initiated
/// fetch runs: the live request's URL and elapsed time (the same readout as
/// the request log's in-flight strip), over a Timeout bar that fills in
/// one-second steps toward that specific request's timeout.
///
/// Polls the core's active-request list on a short timer, showing only
/// requests stamped with this view's operation id (the request-tracking
/// standard: the initiating call obtained the id via `newOperationID`
/// and passed it into the fetch, and the core stamps it onto every
/// request the operation makes — retries included). Between attempts the
/// recovery engine's step for the operation replaces the request line —
/// a new Tor route, a backoff, a wait on a new connection — so the banner
/// says what is happening instead of freezing on the failed request.
/// Cancel stops this operation only (never the connection), and nothing
/// retries it until the user asks again.
struct RequestProgressView: View {
    @Bindable var theme: AppTheme
    let appState: AppState
    /// The tracked operation this banner surfaces — only requests carrying
    /// this id are shown, never unrelated background traffic.
    let opID: UInt64

    @State private var current: UActiveRequest?
    @State private var status: OperationStatus?
    @State private var cancelled = false
    private let timer = Timer.publish(every: 0.25, on: .main, in: .common).autoconnect()

    var body: some View {
        let _ = theme.uiFontScale  // track app text size so fonts refresh live
        VStack(alignment: .leading, spacing: 9) {
            HStack(spacing: 10) {
                ProgressView()
                    .controlSize(.small)
                    .scaleEffect(0.6)
                    .frame(width: 14, height: 14)
                if let message = recoveryMessage {
                    Text(message)
                        .font(Font(MacFont.ui(11.5, weight: .medium)))
                        .foregroundStyle(theme.ink)
                        .lineLimit(1)
                } else {
                    Text(shortURL(current?.url ?? ""))
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(theme.ink)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .help(current?.url ?? "")
                }
                Spacer(minLength: 8)
                if recoveryMessage == nil, current != nil {
                    Text(elapsed(current?.elapsedMs ?? 0))
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(theme.ink3)
                }
                Button(cancelled ? "Cancelling…" : "Cancel") {
                    cancelled = true
                    appState.bridge.cancelOperation(opID)
                }
                .buttonStyle(.plain)
                .font(Font(MacFont.ui(11, weight: .semibold)))
                .foregroundStyle(theme.ink3)
                .disabled(cancelled)
                .help("Stop this request")
            }
            HStack(spacing: 10) {
                if let attempt = attemptText {
                    Text(attempt)
                        .font(Font(MacFont.ui(10, weight: .bold)))
                        .kerning(0.8)
                        .foregroundStyle(theme.ink3)
                } else {
                    Text("TIMEOUT")
                        .font(Font(MacFont.ui(10, weight: .bold)))
                        .kerning(0.8)
                        .foregroundStyle(theme.ink3)
                    timeoutBar
                }
            }
        }
        .padding(.init(top: 10, leading: 12, bottom: 11, trailing: 12))
        .background(theme.surface)
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(theme.line, lineWidth: 1.5))
        .shadow(color: .black.opacity(0.18), radius: 12, y: 4)
        .onAppear(perform: poll)
        .onReceive(timer) { _ in poll() }
        // A new operation id starts the banner over (see RequestProgressOverlay).
        .id(opID)
    }

    /// What the recovery engine is doing between this operation's
    /// attempts; nil while a request is in flight.
    private var recoveryMessage: String? {
        guard let status, status.remedy != nil else { return nil }
        switch status.step {
        case .rotatingCircuit: return "Switching to a new Tor route…"
        case .earningClearance: return "Passing the archive’s security check…"
        case .backingOff(let seconds): return "AO3 asked us to slow down — waiting \(seconds)s…"
        case .reconnecting: return "Waiting for the new Tor connection…"
        case .retrying: return "Retrying…"
        case nil: return "Recovering from a failed request…"
        }
    }

    private var attemptText: String? {
        guard let status, status.remedy != nil else { return nil }
        return "ATTEMPT \(status.attempt + 1) OF \(status.maxAttempts)"
    }

    private var timeoutBar: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(theme.surface2)
                Capsule().fill(theme.accent)
                    .frame(width: max(0, geo.size.width * timeoutFraction))
                    .animation(.easeOut(duration: 0.25), value: timeoutFraction)
            }
        }
        .frame(height: 6)
    }

    /// Whole-second steps toward this request's timeout: with a 30s
    /// timeout each elapsed second advances the bar by 1/30.
    private var timeoutFraction: CGFloat {
        guard let current, current.timeoutSecs > 0 else { return 0 }
        let steps = Double(current.elapsedMs / 1000)
        return CGFloat(min(1, steps / Double(current.timeoutSecs)))
    }

    private func poll() {
        status = appState.bridge.operationStatus(opID)
        // Newest last, per the bridge; keep the previous snapshot through
        // empty gaps between pages.
        if let newest = appState.bridge.getActiveRequests().last(where: { $0.opId == opID }) {
            current = newest
        }
    }

    private func shortURL(_ url: String) -> String {
        url.replacingOccurrences(of: "https://archiveofourown.org", with: "")
    }

    private func elapsed(_ ms: Int64) -> String {
        ms < 1000 ? "\(ms) ms…" : String(format: "%.1f s…", Double(ms) / 1000)
    }
}
