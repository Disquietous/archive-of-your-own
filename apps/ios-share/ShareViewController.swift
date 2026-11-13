import SwiftUI
import UIKit
import UniformTypeIdentifiers

/// "AoYO" in the share sheet. Reads the shared URL (or text holding one)
/// and leaves any web link in the app group for the app to open next time
/// it's in front. Which site a link belongs to, and whether the app has a
/// view for it, is the core's call — the app classifies the link when it
/// takes it and reports one it can't open. Never touches the network,
/// Tor, or the library.
final class ShareViewController: UIViewController {
    private enum Outcome {
        case loading
        case saved
        case rejected(String)
    }

    private var outcome: Outcome = .loading {
        didSet { render() }
    }
    private var host: UIHostingController<ShareResultView>?

    override func viewDidLoad() {
        super.viewDidLoad()
        render()
        Task { await handleSharedItem() }
    }

    private func render() {
        let view = ShareResultView(state: viewState) { [weak self] in
            self?.extensionContext?.completeRequest(returningItems: nil)
        }
        if let host {
            host.rootView = view
            return
        }
        let host = UIHostingController(rootView: view)
        addChild(host)
        host.view.frame = self.view.bounds
        host.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        self.view.addSubview(host.view)
        host.didMove(toParent: self)
        self.host = host
    }

    private var viewState: ShareResultView.State {
        switch outcome {
        case .loading: .loading
        case .saved: .saved
        case .rejected(let message): .rejected(message)
        }
    }

    @MainActor
    private func handleSharedItem() async {
        guard let raw = await sharedString(), let link = Self.webLink(in: raw) else {
            outcome = .rejected("That isn’t a web link.")
            return
        }
        guard SharedLinkInbox.put(link) else {
            outcome = .rejected("AoYO couldn’t receive the link. Open the app and try again.")
            return
        }
        outcome = .saved
    }

    /// The http(s) link a shared string holds: the whole string when it is
    /// one (a scheme is assumed when missing), else the first link inside
    /// the text.
    private static func webLink(in raw: String) -> String? {
        func web(_ url: URL?) -> String? {
            guard let url, let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https",
                  url.host != nil else { return nil }
            return url.absoluteString
        }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if !trimmed.contains(where: \.isWhitespace) {
            return web(URL(string: trimmed.contains("://") ? trimmed : "https://\(trimmed)"))
        }
        guard let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue)
        else { return nil }
        let range = NSRange(trimmed.startIndex..., in: trimmed)
        return web(detector.firstMatch(in: trimmed, options: [], range: range)?.url)
    }

    /// The first shared URL, else the first shared text.
    private func sharedString() async -> String? {
        let providers = (extensionContext?.inputItems as? [NSExtensionItem] ?? [])
            .flatMap { $0.attachments ?? [] }
        for provider in providers where provider.hasItemConformingToTypeIdentifier(UTType.url.identifier) {
            if let url = try? await provider.loadItem(forTypeIdentifier: UTType.url.identifier) as? URL {
                return url.absoluteString
            }
        }
        for provider in providers where provider.hasItemConformingToTypeIdentifier(UTType.plainText.identifier) {
            if let text = try? await provider.loadItem(forTypeIdentifier: UTType.plainText.identifier) as? String {
                return text
            }
        }
        return nil
    }
}

struct ShareResultView: View {
    enum State {
        case loading
        case saved
        case rejected(String)
    }

    let state: State
    let done: () -> Void

    var body: some View {
        NavigationStack {
            VStack(spacing: 16) {
                Spacer()
                switch state {
                case .loading:
                    ProgressView()
                case .saved:
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 44))
                        .foregroundStyle(.green)
                    Text("Sent to AoYO")
                        .font(.title3.weight(.semibold))
                    Text("Open AoYO to see it.")
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                case .rejected(let message):
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 44))
                        .foregroundStyle(.orange)
                    Text("Couldn’t open that link")
                        .font(.title3.weight(.semibold))
                    Text(message)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                Spacer()
            }
            .padding(24)
            .frame(maxWidth: .infinity)
            .navigationTitle("AoYO")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done", action: done)
                }
            }
        }
    }
}
