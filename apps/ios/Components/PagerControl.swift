import SwiftUI

/// Numbered pagination + prev/next, with a jump-to-page field when the
/// listing spans more pages than the ±2 window. State comes from the
/// caller, so any independently paged listing can host one. The iOS
/// counterpart of the macOS `PagerControl`; page buttons wrap rather than
/// scroll when the window doesn't fit.
struct PagerControl: View {
    @Environment(AppTheme.self) private var theme

    let current: Int
    let total: Int
    let hasNext: Bool
    let busy: Bool
    let onGo: (UInt32) -> Void

    @State private var jumpText = ""

    var body: some View {
        let lower = max(1, current - 2)
        let upper = hasNext ? min(current + 2, max(total, current + 2)) : current
        FlowLayout(spacing: 4) {
            pagerButton(symbol: "chevron.left", enabled: current > 1) {
                onGo(UInt32(current - 1))
            }
            ForEach(lower...max(lower, upper), id: \.self) { page in
                Button {
                    onGo(UInt32(page))
                } label: {
                    Text("\(page)")
                        .font(.custom("HankenGrotesk", size: 13).weight(page == current ? .bold : .semibold))
                        .foregroundStyle(page == current ? theme.onAccent : theme.ink2)
                        .frame(minWidth: 32, minHeight: 32)
                        .background(page == current ? theme.accent : theme.surface2)
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(busy)
            }
            pagerButton(symbol: "chevron.right", enabled: hasNext) {
                onGo(UInt32(current + 1))
            }
            // Jump-to-page, once the real total says the window can't reach
            // everything: "⟨field⟩ of 42".
            if total > upper {
                HStack(spacing: 6) {
                    TextField("\(current)", text: $jumpText)
                        .textFieldStyle(.plain)
                        .multilineTextAlignment(.center)
                        .keyboardType(.numberPad)
                        .font(.custom("HankenGrotesk", size: 13).weight(.semibold))
                        .foregroundStyle(theme.ink)
                        .frame(width: 48, height: 32)
                        .background(theme.surface2)
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                        .submitLabel(.go)
                        .onSubmit(jump)
                        .disabled(busy)
                        .accessibilityLabel("Jump to page")
                    Text("of \(total)")
                        .font(Typography.uiSmall())
                        .foregroundStyle(theme.ink3)
                    Button("Go", action: jump)
                        .font(Typography.smallButtonLabel())
                        .foregroundStyle(theme.accent)
                        .disabled(busy || Int(jumpText.trimmingCharacters(in: .whitespaces)) == nil)
                }
                .frame(height: 32)
            }
        }
    }

    private func jump() {
        if let page = Int(jumpText.trimmingCharacters(in: .whitespaces)), page >= 1 {
            onGo(UInt32(min(page, total)))
        }
        jumpText = ""
    }

    private func pagerButton(symbol: String, enabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(enabled ? theme.ink2 : theme.ink3.opacity(0.4))
                .frame(width: 32, height: 32)
                .background(theme.surface2)
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!enabled || busy)
    }
}
