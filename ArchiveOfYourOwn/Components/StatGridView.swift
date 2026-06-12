import SwiftUI

struct StatGridView: View {
    @Environment(AppTheme.self) private var theme

    let stats: [(value: String, label: String)]

    var body: some View {
        HStack(spacing: 1) {
            ForEach(Array(stats.enumerated()), id: \.offset) { index, stat in
                if index > 0 {
                    Rectangle()
                        .fill(theme.line)
                        .frame(width: 1)
                }

                VStack(spacing: 3) {
                    Text(stat.value)
                        .font(.custom("HankenGrotesk", size: 17).weight(.bold))
                        .foregroundStyle(theme.ink)
                    Text(stat.label.uppercased())
                        .font(.custom("HankenGrotesk", size: 10.5).weight(.semibold))
                        .foregroundStyle(theme.ink3)
                        .tracking(0.3)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
            }
        }
        .background(theme.surface)
        .clipShape(RoundedRectangle(cornerRadius: Radius.statGrid))
        .overlay(
            RoundedRectangle(cornerRadius: Radius.statGrid)
                .stroke(theme.line, lineWidth: 1)
        )
    }
}

#Preview {
    StatGridView(stats: [
        (value: "2.8k", label: "Kudos"),
        (value: "84k", label: "Words"),
        (value: "12/20", label: "Chapters"),
        (value: "412", label: "Bookmarks"),
    ])
    .padding()
    .environment(AppTheme())
}
