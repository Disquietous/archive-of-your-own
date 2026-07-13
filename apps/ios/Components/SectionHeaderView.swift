import SwiftUI

struct SectionHeaderView: View {
    @Environment(AppTheme.self) private var theme

    let title: String
    var more: String? = nil
    var onMore: (() -> Void)? = nil

    var body: some View {
        HStack {
            Text(title.uppercased())
                .font(Typography.sectionHeader())
                .tracking(0.08 * 13)
                .foregroundStyle(theme.ink3)

            Spacer()

            if let more, let onMore {
                Button(action: onMore) {
                    Text(more)
                        .font(.custom("HankenGrotesk", size: 13).weight(.semibold))
                        .foregroundStyle(theme.accent)
                }
            }
        }
    }
}

#Preview {
    VStack(spacing: 20) {
        SectionHeaderView(title: "On Your Shelf")
        SectionHeaderView(title: "Popular Tags", more: "See All", onMore: {})
    }
    .padding()
    .environment(AppTheme())
}
