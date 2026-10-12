import AppKit
import SwiftUI

// MARK: - Stats (computed on device)

struct StatsView: View {
    @Bindable var theme: AppTheme
    @Bindable var model: MacAppModel

    var body: some View {
        let _ = theme.uiFontScale  // track app text size so fonts refresh live
        let stats = model.appState.localStats
        ScrollView {
            VStack(spacing: 14) {
                LazyVGrid(columns: [GridItem(.flexible(), spacing: 11), GridItem(.flexible())], spacing: 11) {
                    statCard(Fmt.k(stats.wordsRead), "Words read")
                    statCard("\(stats.worksFinished)", "Works finished")
                    statCard("\(stats.inLibrary)", "In library")
                    statCard("\(stats.downloaded)", "Downloaded")
                }
                Text("Counted on this device from your reading progress. Nothing leaves your library.")
                    .font(Font(MacFont.ui(12)))
                    .foregroundStyle(theme.ink3)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(20)
        }
    }

    private func statCard(_ value: String, _ label: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(value)
                .font(Font(MacFont.serif(28, weight: .semibold)))
                .foregroundStyle(theme.accent)
            Text(label)
                .font(Font(MacFont.ui(12, weight: .semibold)))
                .foregroundStyle(theme.ink3)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(theme.surface)
        .clipShape(RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(theme.line, lineWidth: 1))
    }
}
