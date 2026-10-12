import AppKit

/// Toolbar button for "Download all" on a work list (Currently Reading, a
/// reading list): downloads every listed work not yet offline; while the
/// batch runs it turns into Stop (the batch ends after the work in flight).
@MainActor
final class BulkDownloadButton {
    let button: ToolButton
    private let appState: AppState
    private var ids: [String] = []

    init(theme: AppTheme, appState: AppState) {
        self.appState = appState
        var tap: () -> Void = {}
        button = ToolButton(theme: theme, symbol: "arrow.down.circle", tooltip: "Download all") { tap() }
        tap = { [weak self] in self?.tapped() }
    }

    /// Point the button at the list's current works and refresh its state.
    /// Callers render under observation, so reading `bulkDownload` here
    /// re-renders the toolbar as the batch progresses.
    func update(ids: [String]) -> ToolButton {
        self.ids = ids
        if let progress = appState.bulkDownload {
            button.setSymbol("stop.circle")
            button.isEnabled = true
            button.toolTip = "\(progress.label) — click to stop after this work"
        } else {
            let pending = appState.pendingDownloads(ids).count
            button.setSymbol("arrow.down.circle")
            button.isEnabled = pending > 0
            button.toolTip = pending > 0
                ? "Download all \(pending) \(pending == 1 ? "work" : "works") not yet offline"
                : "Every work here is already offline"
        }
        return button
    }

    /// Toolbar subtitle suffix while a batch runs.
    var statusSuffix: String {
        appState.bulkDownload.map { " · \($0.label)" } ?? ""
    }

    private func tapped() {
        if appState.bulkDownload != nil {
            appState.stopBulkDownload()
        } else {
            appState.downloadAll(ids)
        }
    }
}
