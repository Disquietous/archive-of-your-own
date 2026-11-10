import SwiftUI

/// The reaction control for a source whose shape is a star rating
/// (design/source-controls-plan.md): one star per step up to `max`. A tap
/// sets that value; tapping the current value clears it. Faded while the
/// request is in flight; the gate's reason shows when it is disabled.
struct StarRatingView: View {
    @Environment(AppTheme.self) private var theme
    let max: UInt8
    let mine: UInt8?
    let pending: Bool
    let gate: Gate
    let verb: String
    let onSelect: (UInt8?) -> Void

    private var reason: String? {
        if case .disabled(let reason) = gate { return reason }
        return nil
    }

    var body: some View {
        HStack(spacing: 6) {
            HStack(spacing: 2) {
                ForEach(1...Int(Swift.max(1, max)), id: \.self) { step in
                    let on = step <= Int(mine ?? 0)
                    Button {
                        onSelect(UInt8(step) == mine ? nil : UInt8(step))
                    } label: {
                        Image(systemName: on ? "star.fill" : "star")
                            .font(.system(size: 14, weight: .medium))
                            .foregroundStyle((on ? theme.accent : theme.ink3).opacity(pending ? 0.45 : 1))
                            .frame(minWidth: 22, minHeight: 28)
                    }
                    .buttonStyle(IconButtonPressStyle())
                    .disabled(pending || gate != .enabled)
                    .accessibilityLabel("\(step) of \(max) stars")
                }
            }
            if let reason {
                Text(reason)
                    .font(Typography.uiCaption())
                    .foregroundStyle(theme.ink3)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(mine.map { "\(verb) — yours: \($0) of \(max)" } ?? verb)
    }
}
