import SwiftUI

/// Reading stats computed on device from progress + cached works.
struct StatsScreen: View {
    @Environment(AppTheme.self) private var theme
    @Environment(AppState.self) private var state

    var body: some View {
        let stats = state.localStats
        ZStack(alignment: .top) {
            ScrollView {
                VStack(spacing: 14) {
                    LazyVGrid(columns: [GridItem(.flexible(), spacing: 11), GridItem(.flexible())],
                              spacing: 11) {
                        statCard(stats.wordsRead.abbreviated, "Words read")
                        statCard("\(stats.worksFinished)", "Works finished")
                        statCard("\(stats.inLibrary)", "In library")
                        statCard("\(stats.downloaded)", "Downloaded")
                    }
                    Text("Counted on this device from your reading progress. Nothing leaves your library.")
                        .font(.custom("HankenGrotesk", size: 12.5))
                        .foregroundStyle(theme.ink3)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(theme.pad)
            }
            .contentMargins(.top, ScreenChromeMetrics.height, for: .scrollContent)

            ScreenChrome(title: "Reading Stats")
        }
        .libraryScreen()
    }

    private func statCard(_ value: String, _ label: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(value)
                .font(Typography.browseTitle())
                .foregroundStyle(theme.accent)
            Text(label)
                .font(.custom("HankenGrotesk", size: 12).weight(.semibold))
                .foregroundStyle(theme.ink3)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(theme.surface)
        .clipShape(RoundedRectangle(cornerRadius: Radius.statGrid))
        .overlay(RoundedRectangle(cornerRadius: Radius.statGrid).stroke(theme.line, lineWidth: 1))
    }
}
