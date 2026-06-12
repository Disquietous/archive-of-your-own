import SwiftUI

struct PrivacyPillView: View {
    @Environment(AppTheme.self) private var theme
    @Environment(AppState.self) private var state

    var onTap: () -> Void

    private var dotColor: Color {
        state.torStatus.isConnected ? theme.sage : Color(hex: "CE514D")
    }

    private var pillLabel: String {
        if let username = state.ao3Username, !username.isEmpty {
            return username
        }
        return "Guest"
    }

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 7) {
                Circle()
                    .fill(dotColor)
                    .frame(width: 7, height: 7)
                    .shadow(color: dotColor.opacity(0.5), radius: 4, x: 0, y: 0)

                Text(pillLabel)
                    .font(.custom("HankenGrotesk", size: 13).weight(.semibold))
                    .foregroundStyle(theme.ink)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            .padding(.horizontal, 12)
            .frame(height: 34)
            .frame(maxWidth: 150)
            .background(theme.surface)
            .clipShape(RoundedRectangle(cornerRadius: Radius.chip))
            .overlay(
                RoundedRectangle(cornerRadius: Radius.chip)
                    .stroke(theme.line, lineWidth: 1)
            )
            .overlay(alignment: .topTrailing) {
                if state.inboxUnreadCount > 0 {
                    Text("\(state.inboxUnreadCount)")
                        .font(.custom("HankenGrotesk", size: 10).weight(.bold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 5)
                        .frame(minWidth: 18, minHeight: 18)
                        .background(Color(hex: "CE514D"))
                        .clipShape(Capsule())
                        .offset(x: 6, y: -6)
                }
            }
            .shadow(color: Color.black.opacity(0.04), radius: 2, x: 0, y: 1)
        }
        .fixedSize(horizontal: false, vertical: true)
        .buttonStyle(ChipPressStyle())
    }
}

#Preview {
    PrivacyPillView(onTap: {})
        .environment(AppTheme())
        .environment(AppState())
}
