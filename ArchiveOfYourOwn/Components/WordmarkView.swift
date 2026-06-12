import SwiftUI

struct WordmarkView: View {
    @Environment(AppTheme.self) private var theme

    var body: some View {
        Text("Archive of Your Own")
            .font(Typography.wordmark())
            .tracking(-0.3)
            .foregroundStyle(theme.ink)
    }
}

#Preview {
    WordmarkView()
        .environment(AppTheme())
}
