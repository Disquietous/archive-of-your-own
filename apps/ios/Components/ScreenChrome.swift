import SwiftUI

/// The floating top bar every Library drill-in screen draws over its
/// scroll view: back chevron, title (+ optional subtitle), the screen's
/// own trailing controls, and the privacy pill. Screens hide the system
/// navigation bar and place this in a `ZStack(alignment: .top)`.
struct ScreenChrome<Trailing: View>: View {
    @Environment(AppTheme.self) private var theme
    @Environment(NavigationState.self) private var nav
    @Environment(\.dismiss) private var dismiss

    let title: String
    let subtitle: String?
    let trailing: () -> Trailing

    init(title: String, subtitle: String? = nil, @ViewBuilder trailing: @escaping () -> Trailing) {
        self.title = title
        self.subtitle = subtitle
        self.trailing = trailing
    }

    var body: some View {
        HStack(spacing: 8) {
            Button { dismiss() } label: {
                Image(systemName: "chevron.left")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(theme.ink)
                    .frame(width: 36, height: 36)
            }
            .buttonStyle(IconButtonPressStyle())

            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(Typography.uiBody())
                    .foregroundStyle(theme.ink)
                    .lineLimit(1)
                if let subtitle, !subtitle.isEmpty {
                    Text(subtitle)
                        .font(.custom("HankenGrotesk", size: 11).weight(.medium))
                        .foregroundStyle(theme.ink3)
                        .lineLimit(1)
                }
            }

            Spacer(minLength: 4)

            trailing()

            PrivacyPillView {
                nav.presentedSheet = .privacy
            }
        }
        .padding(.horizontal, theme.pad)
        .padding(.top, 8)
        .padding(.bottom, 8)
        .background(
            theme.bg.opacity(0.95)
                .shadow(.drop(color: .black.opacity(0.05), radius: 4, y: 2))
        )
    }
}

extension ScreenChrome where Trailing == EmptyView {
    init(title: String, subtitle: String? = nil) {
        self.title = title
        self.subtitle = subtitle
        self.trailing = { EmptyView() }
    }
}

/// Height the chrome occupies; content clears it via a top content margin.
enum ScreenChromeMetrics {
    static let height: CGFloat = 56
}

/// A 36pt icon button for the chrome's trailing slot.
struct ChromeIconButton: View {
    @Environment(AppTheme.self) private var theme

    let symbol: String
    var tint: Color? = nil
    var isBusy = false
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            Group {
                if isBusy {
                    ProgressView().controlSize(.small).tint(theme.ink2)
                } else {
                    Image(systemName: symbol)
                        .font(.system(size: 16, weight: .medium))
                        .foregroundStyle(tint ?? theme.ink2)
                }
            }
            .frame(width: 36, height: 36)
        }
        .buttonStyle(IconButtonPressStyle())
    }
}

/// The standard modifiers for a Library drill-in screen: theme ground,
/// hidden system bars (the screen draws `ScreenChrome` itself).
struct LibraryScreenStyle: ViewModifier {
    @Environment(AppTheme.self) private var theme

    func body(content: Content) -> some View {
        content
            .background(theme.bg)
            .navigationBarBackButtonHidden(true)
            .toolbar(.hidden, for: .tabBar)
            .toolbar(.hidden, for: .navigationBar)
    }
}

extension View {
    func libraryScreen() -> some View {
        modifier(LibraryScreenStyle())
    }
}
