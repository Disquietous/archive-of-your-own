import SwiftUI

struct EmptyStateView: View {
    @Environment(AppTheme.self) private var theme

    let systemImage: String
    let title: String
    let subtitle: String

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: systemImage)
                .font(.system(size: 40))
                .foregroundStyle(theme.line2)

            Text(title)
                .font(Typography.emptyTitle())
                .foregroundStyle(theme.ink2)

            Text(subtitle)
                .font(.custom("HankenGrotesk", size: 13.5))
                .foregroundStyle(theme.ink3)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

#Preview {
    EmptyStateView(
        systemImage: "book.closed",
        title: "No Downloads Yet",
        subtitle: "Works you download will appear here for offline reading."
    )
    .environment(AppTheme())
}
