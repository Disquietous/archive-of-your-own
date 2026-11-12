import SwiftUI

/// The reaction control for a source whose shape is a star rating
/// (design/source-controls-plan.md): the site's average to one decimal
/// beside a single star ("4.1 ★"). A tap drops a menu of 1…`max` stars
/// with the reader's own rating checked; picking a different value sends
/// it. The star is filled once the reader has rated. Faded while the
/// request is in flight; a closed gate's reason leads the menu.
struct StarRatingView: View {
    @Environment(AppTheme.self) private var theme
    let max: UInt8
    let mine: UInt8?
    /// The site's average as shown ("4.1"); nil when the work is unrated.
    let average: String?
    let pending: Bool
    let gate: Gate
    let verb: String
    let onSelect: (UInt8?) -> Void

    private var reason: String? {
        if case .disabled(let reason) = gate, !reason.isEmpty { return reason }
        return nil
    }

    var body: some View {
        Menu {
            if let reason {
                Section(reason) { options }
            } else {
                options
            }
        } label: {
            HStack(spacing: 4) {
                if let average {
                    Text(average)
                        .font(Typography.uiSmall())
                        .foregroundStyle(theme.ink2)
                }
                Image(systemName: mine != nil ? "star.fill" : "star")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(mine != nil ? theme.accent : theme.ink3)
            }
            .opacity(pending ? 0.45 : 1)
            .frame(minHeight: 28)
            .contentShape(Rectangle())
        }
        .accessibilityLabel(mine.map { "\(verb) — yours: \($0) of \(max)" } ?? verb)
        .accessibilityValue(average.map { "Rated \($0) of \(max)" } ?? "Not yet rated")
    }

    @ViewBuilder private var options: some View {
        ForEach(1...Int(Swift.max(1, max)), id: \.self) { step in
            Button {
                if UInt8(step) != mine { onSelect(UInt8(step)) }
            } label: {
                if UInt8(step) == mine {
                    Label(step == 1 ? "1 star" : "\(step) stars", systemImage: "checkmark")
                } else {
                    Text(step == 1 ? "1 star" : "\(step) stars")
                }
            }
            .disabled(pending || gate != .enabled)
        }
    }
}
