import SwiftUI

struct ChipView: View {
    @Environment(AppTheme.self) private var theme

    let label: String
    var isSelected: Bool = false
    var onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            Text(label)
                .font(.custom("HankenGrotesk", size: 13).weight(.semibold))
                .foregroundStyle(isSelected ? theme.onAccent : theme.ink)
                .padding(.horizontal, 14)
                .frame(height: 33)
                .background(isSelected ? theme.accent : theme.surface)
                .clipShape(RoundedRectangle(cornerRadius: Radius.chip))
                .overlay(
                    RoundedRectangle(cornerRadius: Radius.chip)
                        .stroke(isSelected ? theme.accent : theme.line, lineWidth: 1)
                )
        }
        .buttonStyle(ChipPressStyle())
    }
}

#Preview {
    HStack {
        ChipView(label: "Slow Burn", isSelected: false, onTap: {})
        ChipView(label: "Friends to Lovers", isSelected: true, onTap: {})
    }
    .padding()
    .environment(AppTheme())
}
