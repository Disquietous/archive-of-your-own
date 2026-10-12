import SwiftUI

/// "Checking 3 of 12 · Stop" while a What's New check runs. Stop ends the
/// run at the next item; the queue is kept, so the next check resumes it.
/// Pause/resume isn't offered on the phone — leaving the app suspends the
/// run anyway.
struct WhatsNewCheckStatusBar: View {
    @Environment(AppTheme.self) private var theme
    @Environment(AppState.self) private var state

    var body: some View {
        if state.isCheckingWhatsNew {
            HStack(spacing: 10) {
                ProgressView().controlSize(.small).tint(theme.ink3)
                Text(statusText)
                    .font(.custom("HankenGrotesk", size: 12).weight(.medium))
                    .foregroundStyle(theme.ink3)
                    .lineLimit(1)
                Spacer()
                Button("Stop") { state.stopWhatsNewCheck() }
                    .font(Typography.smallButtonLabel())
                    .foregroundStyle(theme.accent)
                    .buttonStyle(ButtonPressStyle())
                    .disabled(state.checkMonitor.stopRequested)
            }
        }
    }

    private var statusText: String {
        if state.checkMonitor.stopRequested { return "Stopping…" }
        if let message = state.whatsNewCheckTask.statusMessage { return message }
        let total = state.whatsNewCheckTotal
        guard total > 0 else { return "Starting check…" }
        let done = max(0, total - state.whatsNewCheckRemaining)
        return "Checking \(min(done + 1, total)) of \(total)"
    }
}
