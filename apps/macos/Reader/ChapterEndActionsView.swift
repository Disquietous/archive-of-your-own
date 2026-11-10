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
        let controls = appState.workControls(workID)
        let hasKudos = appState.kudosGivenWorkIDs.contains(workID)
        let pending = appState.kudosPendingWorkIDs.contains(workID)
        let verb = controls?.vocabulary.reactionVerb ?? "Leave kudos"
        HStack(spacing: 12) {
            Spacer()
            switch controls?.reaction ?? .kudos(given: false, gate: .enabled) {
            case .kudos(_, let gate):
                pill(symbol: hasKudos || pending ? "heart.fill" : "heart",
                     label: hasKudos ? "Kudos left" : pending ? "Leaving kudos…" : "Kudos",
                     tint: hasKudos ? theme.danger : pending ? theme.danger.opacity(0.5) : theme.ink2) {
                    appState.giveKudos(workID)
                }
                .disabled(hasKudos || pending || gate != .enabled)
                .help(gateReason(gate) ?? verb)
            case .starRating(let max, _, let gate):
                starPill(max: max, mine: appState.workReactions[workID], pending: pending, gate: gate, verb: verb)
            case .none:
                EmptyView()
            }
            if controls.map({ $0.discussion != .none }) ?? true {
                let title = controls?.vocabulary.discussionTitle ?? "Comments"
                pill(symbol: "bubble.left.and.bubble.right", label: "\(title) · Leave one",
                     tint: theme.ink2, action: onComments)
                    .help("Open the discussion (⌥⌘C)")
            }
            Spacer()
        }
    }

    private func gateReason(_ gate: Gate) -> String? {
        if case .disabled(let reason) = gate { return reason }
        return nil
    }

    /// One star per step; a click sets it, a click on the current value
    /// clears it. Faded while the request is in flight.
    private func starPill(max: UInt8, mine: UInt8?, pending: Bool, gate: Gate, verb: String) -> some View {
        HStack(spacing: 2) {
            ForEach(1...Int(Swift.max(1, max)), id: \.self) { step in
                let on = step <= Int(mine ?? 0)
                Button {
                    appState.rateWork(workID, stars: UInt8(step) == mine ? nil : UInt8(step))
                } label: {
                    Image(systemName: on ? "star.fill" : "star")
                        .foregroundStyle((on ? theme.accent : theme.ink3).opacity(pending ? 0.45 : 1))
                }
                .buttonStyle(.plain)
                .disabled(pending || gate != .enabled)
            }
        }
        .font(Font(MacFont.ui(13, weight: .semibold)))
        .padding(.horizontal, 14)
        .frame(height: 32)
        .background(Capsule().fill(theme.surface))
        .overlay(Capsule().stroke(theme.line, lineWidth: 1))
        .help(gateReason(gate) ?? (mine.map { "\(verb) — yours: \($0) of \(max)" } ?? verb))
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
