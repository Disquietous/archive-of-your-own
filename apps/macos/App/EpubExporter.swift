import AppKit
import UniformTypeIdentifiers

/// Save-panel front end for the Rust EPUB export. The Rust side requires
/// cached chapters, so works should be downloaded first — the error message
/// says so when they aren't.
enum EpubExporter {
    static func export(work: Work, appState: AppState) {
        guard let workId = UInt64(work.id) else { return }

        let panel = NSSavePanel()
        panel.title = "Export as EPUB"
        if let epub = UTType(filenameExtension: "epub") {
            panel.allowedContentTypes = [epub]
        }
        panel.nameFieldStringValue = suggestedFilename(for: work)
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return }

        do {
            try appState.bridge.exportEpub(workId: workId, path: url.path)
            NSWorkspace.shared.activateFileViewerSelecting([url])
        } catch {
            let alert = NSAlert()
            alert.alertStyle = .warning
            alert.messageText = "Couldn’t export EPUB"
            alert.informativeText = error.localizedDescription
            alert.runModal()
        }
    }

    private static func suggestedFilename(for work: Work) -> String {
        let cleaned = work.title
            .components(separatedBy: CharacterSet(charactersIn: "/:\\"))
            .joined(separator: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return "\(cleaned.isEmpty ? "work-\(work.id)" : cleaned).epub"
    }
}
