import SwiftUI

struct ThemeBackgroundView: View {
    @Environment(AppTheme.self) private var theme

    var body: some View {
        ZStack {
            theme.bg

            switch theme.activeTheme.backgroundType {
            case .solid:
                EmptyView()
            case .image:
                if let img = theme.backgroundImage {
                    Image(uiImage: img)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                        .opacity(theme.activeTheme.backgroundDimOpacity)
                }
            case .tiledPattern:
                if let img = theme.backgroundImage {
                    Image(uiImage: img)
                        .resizable(resizingMode: .tile)
                        .opacity(theme.activeTheme.backgroundDimOpacity)
                }
            }
        }
        .ignoresSafeArea()
    }
}
