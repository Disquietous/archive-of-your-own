import SwiftUI

/// "Download All" for a list's menu: every listed work not yet offline.
struct BulkDownloadMenuItem: View {
    @Environment(AppState.self) private var state
    let ids: () -> [String]

    var body: some View {
        let pending = state.pendingDownloads(ids()).count
        Button {
            state.downloadAll(ids())
        } label: {
            Label(pending > 0 ? "Download All (\(pending))" : "Download All",
                  systemImage: "arrow.down.circle")
        }
        .disabled(pending == 0 || state.bulkDownload != nil)
    }
}

/// Status line above a list while "Download All" runs, with Stop.
struct BulkDownloadStatusBar: View {
    @Environment(AppTheme.self) private var theme
    @Environment(AppState.self) private var state

    var body: some View {
        if let progress = state.bulkDownload {
            HStack(spacing: 10) {
                ProgressView().controlSize(.small).tint(theme.ink3)
                Text(state.bulkDownloadStopRequested ? "Stopping after this work…" : progress.label)
                    .font(.custom("HankenGrotesk", size: 12).weight(.medium))
                    .foregroundStyle(theme.ink3)
                Spacer()
                Button("Stop") { state.stopBulkDownload() }
                    .font(Typography.smallButtonLabel())
                    .foregroundStyle(theme.accent)
                    .buttonStyle(ButtonPressStyle())
            }
        }
    }
}
