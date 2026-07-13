import SwiftUI

struct SummaryBoxView: View {
    @Environment(AppTheme.self) private var theme

    let summary: String

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("SUMMARY")
                .font(.custom("HankenGrotesk", size: 11.5).weight(.bold))
                .foregroundStyle(theme.ink3)
                .tracking(0.5)

            Text(summary)
                .font(Typography.summaryBodyItalic())
                .foregroundStyle(theme.ink2)
                .lineSpacing(4)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(theme.surface)
        .clipShape(RoundedRectangle(cornerRadius: Radius.summaryBox))
        .overlay(
            RoundedRectangle(cornerRadius: Radius.summaryBox)
                .stroke(theme.line, lineWidth: 1)
        )
    }
}

#Preview {
    SummaryBoxView(
        summary: "When a series of impossible thefts plague the British Museum, Holmes finds himself entangled in a web of secrets that hits closer to home than he'd like."
    )
    .padding()
    .environment(AppTheme())
}
