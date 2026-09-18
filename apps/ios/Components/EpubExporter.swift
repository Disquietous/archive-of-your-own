import SwiftUI
import UIKit

/// iOS front end for the Rust EPUB export: writes the file into the temp
/// directory and hands it to the system share sheet (Books, Files, AirDrop
/// come free). The Rust side requires cached chapters, so works should be
/// downloaded first — the thrown error says so when they aren't.
enum EpubExporter {
    struct Exported: Identifiable {
        let url: URL
        var id: String { url.path }
    }

    @MainActor
    static func export(work: Work, appState: AppState) throws -> Exported {
        guard let workId = UInt64(work.id) else {
            throw NSError(domain: "EpubExporter", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "Sample works can’t be exported."])
        }
        let url = FileManager.default.temporaryDirectory.appending(path: suggestedFilename(for: work))
        try? FileManager.default.removeItem(at: url)
        try appState.bridge.exportEpub(workId: workId, path: url.path)
        return Exported(url: url)
    }

    private static func suggestedFilename(for work: Work) -> String {
        let cleaned = work.title
            .components(separatedBy: CharacterSet(charactersIn: "/:\\"))
            .joined(separator: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return "\(cleaned.isEmpty ? "work-\(work.id)" : cleaned).epub"
    }
}

/// The system share sheet for an exported file.
struct ShareSheet: UIViewControllerRepresentable {
    let items: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }

    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}
