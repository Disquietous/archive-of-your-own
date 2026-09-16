import SwiftUI

/// Floating banner shown over a screen while a user-initiated fetch runs:
/// the live request's path and elapsed time over a Timeout bar that fills
/// in one-second steps toward that request's timeout. The iOS counterpart
/// of the macOS `RequestProgressView`.
///
/// Polls the core's active-request list on a short timer, showing only
/// requests stamped with this banner's operation id (the request-tracking
/// standard: the initiating call obtained the id via `newOperationID` and
/// passed it into the fetch, and the core stamps it onto every request the
/// operation makes — retries included). When the operation's requests go
/// quiet mid-operation (the gap between a failure and its retry, or between
/// pages of a multi-page fetch), the last request stays on screen so the
/// banner never flickers blank.
struct RequestProgressBanner: View {
    @Environment(AppTheme.self) private var theme
    @Environment(AppState.self) private var state

    /// The tracked operation this banner surfaces — only requests carrying
    /// this id are shown, never unrelated background traffic.
    let opID: UInt64
    /// Aborts exactly this operation (the core cancels its requests).
    var onCancel: (() -> Void)?

    @State private var current: UActiveRequest?
    private let timer = Timer.publish(every: 0.25, on: .main, in: .common).autoconnect()

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                ProgressView()
                    .controlSize(.small)
                    .tint(theme.ink3)
                Text(shortURL(current?.url ?? ""))
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(theme.ink)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 8)
                Text(elapsed(current?.elapsedMs ?? 0))
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(theme.ink3)
                    .monospacedDigit()
                if let onCancel {
                    Button(action: onCancel) {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 15, weight: .medium))
                            .foregroundStyle(theme.ink3)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Cancel")
                }
            }
            HStack(spacing: 10) {
                Text("TIMEOUT")
                    .font(.custom("HankenGrotesk", size: 10).weight(.bold))
                    .tracking(0.8)
                    .foregroundStyle(theme.ink3)
                timeoutBar
            }
        }
        .padding(.init(top: 10, leading: 12, bottom: 11, trailing: 12))
        .background(theme.surface)
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(theme.line, lineWidth: 1))
        .shadow(color: .black.opacity(0.14), radius: 10, y: 4)
        .onAppear(perform: poll)
        .onReceive(timer) { _ in poll() }
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
        // Newest last, per the bridge; keep the previous snapshot through
        // empty gaps (see the type comment).
        if let newest = state.bridge.getActiveRequests().last(where: { $0.opId == opID }) {
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
