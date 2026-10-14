import SwiftUI

/// Under each chapter: leave kudos, or open the discussion with the
/// composer focused — the moment readers most want to respond.
struct ChapterEndActionsView: View {
    @Bindable var theme: AppTheme
    @Bindable var appState: AppState
    let workID: String
    let onComments: () -> Void

    var body: some View {
        let _ = theme.uiFontScale  // track app text size so fonts refresh live
        let hasKudos = appState.kudosGivenWorkIDs.contains(workID)
        let kudosPending = appState.kudosPendingWorkIDs.contains(workID)
        HStack(spacing: 12) {
            Spacer()
            pill(symbol: hasKudos || kudosPending ? "heart.fill" : "heart",
                 label: hasKudos ? "Kudos left" : kudosPending ? "Leaving kudos…" : "Kudos",
                 tint: hasKudos ? theme.danger : kudosPending ? theme.danger.opacity(0.5) : theme.ink2) {
                appState.giveKudos(workID)
            }
            .disabled(hasKudos || kudosPending || appState.ao3Username == nil)
            .help(appState.ao3Username == nil ? "Sign in to AO3 to leave kudos" : "Leave kudos on AO3")
            pill(symbol: "bubble.left.and.bubble.right", label: "Comments · Leave one",
                 tint: theme.ink2, action: onComments)
                .help("Open the discussion (⌥⌘C)")
            Spacer()
        }
    }

    private func pill(symbol: String, label: String, tint: Color, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: symbol)
                Text(label)
            }
            .font(Font(MacFont.ui(13, weight: .semibold)))
            .foregroundStyle(tint)
            .padding(.horizontal, 14)
            .frame(height: 32)
            .background(Capsule().fill(theme.surface))
            .overlay(Capsule().stroke(theme.line, lineWidth: 1))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
    }
}
