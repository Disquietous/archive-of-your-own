import SwiftUI
import UIKit
import UniformTypeIdentifiers

/// "AoYO" in the share sheet. Reads the shared URL (or text holding one),
/// classifies it with the app's own `AO3Link` rules, and — only for a link
/// the app can open — leaves it in the app group for the app to open next
/// time it's in front. Never touches the network, Tor, or the library.
final class ShareViewController: UIViewController {
    private enum Outcome {
        case loading
        case saved(kind: String)
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
        case .saved(let kind): .saved(kind)
        case .rejected(let message): .rejected(message)
        }
    }

    @MainActor
    private func handleSharedItem() async {
        guard let raw = await sharedString() else {
            outcome = .rejected("\(AO3Link.Rejection.notAO3.message) \(AO3Link.supportedSummary)")
            return
        }
        switch AO3Link.classify(raw) {
        case .failure(let rejection):
            outcome = .rejected("\(rejection.message) \(AO3Link.supportedSummary)")
        case .success(let link):
            guard SharedLinkInbox.put(raw) else {
                outcome = .rejected("AoYO couldn’t receive the link. Open the app and try again.")
                return
            }
            outcome = .saved(kind: Self.kindName(link))
        }
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

    private static func kindName(_ link: AO3Link) -> String {
        switch link {
        case .work, .entireWork: "work"
        case .chapter: "chapter"
        case .user: "author"
        case .series: "series"
        case .collection: "collection"
        case .tag: "tag"
        }
    }
}

struct ShareResultView: View {
    enum State {
        case loading
        case saved(String)
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
                case .saved(let kind):
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 44))
                        .foregroundStyle(.green)
                    Text("Sent to AoYO")
                        .font(.title3.weight(.semibold))
                    Text("Open AoYO to see this \(kind).")
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
