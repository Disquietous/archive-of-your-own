import UIKit
import WebKit

/// A site's own page shown to the user in a sheet, for the two things only
/// they can do there: pass its human check (Cloudflare's checkbox) when a
/// direct request comes back challenged, or sign in to their account. The
/// web view runs on the system connection — the same path the app's own
/// direct requests take, so it is only ever asked for off Tor — with a
/// throwaway data store. When the cookie that marks success appears (the
/// clearance cookie, or the site's login cookie), every cookie the site
/// set is handed back with the web view's User-Agent, which the clearance
/// is bound to, and the sheet closes itself. Nothing the page renders
/// reaches the app's own views.
@MainActor
final class SiteSheetController: UIViewController, WKNavigationDelegate, WKHTTPCookieStoreObserver,
                                 UIAdaptivePresentationControllerDelegate {

    enum Failure: Error, LocalizedError {
        case cancelled
        case loadFailed(String)
        case noWindow

        var errorDescription: String? {
            switch self {
            case .cancelled: "The window was closed before it finished."
            case .loadFailed(let message): "The page did not load: \(message)"
            case .noWindow: "There is no window to show the page in."
            }
        }
    }

    /// What the sheet is up for, and so which cookie ends it.
    enum Purpose {
        case humanCheck
        /// Done when a cookie whose name starts with the prefix arrives.
        case signIn(loginCookiePrefix: String)

        func isDone(_ cookies: [HTTPCookie]) -> Bool {
            switch self {
            case .humanCheck: cookies.contains { $0.name == "cf_clearance" }
            case .signIn(let prefix): cookies.contains { $0.name.hasPrefix(prefix) && !$0.value.isEmpty }
            }
        }

        var title: String {
            switch self {
            case .humanCheck: "Human check"
            case .signIn: "Sign in"
            }
        }
    }

    /// Show `url` over whatever is on screen and wait for it to finish.
    static func present(url: URL, purpose: Purpose) async throws -> SiteClearance {
        guard let presenter = topViewController else { throw Failure.noWindow }
        let controller = SiteSheetController(url: url, purpose: purpose)
        return try await withCheckedThrowingContinuation { continuation in
            controller.continuation = continuation
            let nav = UINavigationController(rootViewController: controller)
            nav.presentationController?.delegate = controller
            presenter.present(nav, animated: true)
        }
    }

    private static var topViewController: UIViewController? {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        let scene = scenes.first { $0.activationState == .foregroundActive } ?? scenes.first
        var top = scene?.keyWindow?.rootViewController
        while let presented = top?.presentedViewController { top = presented }
        return top
    }

    private let url: URL
    private let site: String
    private let purpose: Purpose
    private let webView: WKWebView
    private var continuation: CheckedContinuation<SiteClearance, Error>?
    private var finished = false

    private init(url: URL, purpose: Purpose) {
        self.url = url
        self.purpose = purpose
        let host = url.host ?? ""
        site = host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
        let config = WKWebViewConfiguration()
        config.websiteDataStore = WKWebsiteDataStore.nonPersistent()
        webView = WKWebView(frame: .zero, configuration: config)
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = purpose.title
        navigationItem.prompt = site
        navigationItem.leftBarButtonItem = UIBarButtonItem(systemItem: .cancel, primaryAction: UIAction { [weak self] _ in
            self?.finish(.failure(Failure.cancelled))
        })
        view.backgroundColor = .systemBackground
        webView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(webView)
        NSLayoutConstraint.activate([
            webView.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            webView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            webView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            webView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
        webView.navigationDelegate = self
        webView.configuration.websiteDataStore.httpCookieStore.add(self)
        webView.load(URLRequest(url: url))
    }

    // MARK: - Finishing

    /// The page sets its cookie and reloads; either event lands here.
    private func checkForCookie() {
        guard !finished else { return }
        webView.configuration.websiteDataStore.httpCookieStore.getAllCookies { [weak self] cookies in
            guard let self, !self.finished else { return }
            let ours = cookies.filter { Self.belongs($0.domain, to: self.site) }
            guard self.purpose.isDone(ours) else { return }
            self.webView.evaluateJavaScript("navigator.userAgent") { [weak self] result, _ in
                guard let self, !self.finished else { return }
                self.finish(.success(SiteClearance(
                    cookies: ours.map { "\($0.name)=\($0.value)" },
                    userAgent: (result as? String) ?? "")))
            }
        }
    }

    /// Cookie domains come as "www.site.com" or ".site.com".
    private static func belongs(_ domain: String, to site: String) -> Bool {
        let bare = domain.hasPrefix(".") ? String(domain.dropFirst()) : domain
        return bare == site || bare.hasSuffix("." + site)
    }

    nonisolated func cookiesDidChange(in cookieStore: WKHTTPCookieStore) {
        Task { @MainActor in self.checkForCookie() }
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        checkForCookie()
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        // Submitting a form cancels the page load under it.
        if (error as NSError).code == NSURLErrorCancelled { return }
        finish(.failure(Failure.loadFailed(error.localizedDescription)))
    }

    /// Swiped down.
    func presentationControllerDidDismiss(_ presentationController: UIPresentationController) {
        finish(.failure(Failure.cancelled))
    }

    private func finish(_ result: Result<SiteClearance, Error>) {
        guard !finished else { return }
        finished = true
        webView.stopLoading()
        webView.navigationDelegate = nil
        webView.configuration.websiteDataStore.httpCookieStore.remove(self)
        let continuation = self.continuation
        self.continuation = nil
        if presentingViewController != nil {
            dismiss(animated: true) { continuation?.resume(with: result) }
        } else {
            continuation?.resume(with: result)
        }
    }
}
