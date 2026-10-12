import SwiftUI

/// "Stopped at page 4 of 9 · Resume" — a works crawl that ended part-way
/// (cancelled, or the app left the foreground). The works fetched so far
/// are kept; Resume continues from the page it stopped on.
struct CrawlStoppedRow: View {
    @Environment(AppTheme.self) private var theme
    let stop: AppState.CrawlStop
    let resume: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "pause.circle")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(theme.ink3)
            Text(stop.label)
                .font(.custom("HankenGrotesk", size: 12).weight(.medium))
                .foregroundStyle(theme.ink3)
            Spacer()
            Button("Resume", action: resume)
                .font(Typography.smallButtonLabel())
                .foregroundStyle(theme.accent)
                .buttonStyle(ButtonPressStyle())
        }
    }
}
