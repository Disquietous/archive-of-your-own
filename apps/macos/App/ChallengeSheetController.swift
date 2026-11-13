import AppKit
import WebKit

/// A site's own page shown to the user in a sheet, for the two things only
/// they can do there: pass its human check (Cloudflare's checkbox) when a
/// direct request comes back challenged, or sign in to their account. The web view runs
/// on the system connection — the same path the app's own direct requests
/// take, so it is only ever asked for off Tor — with a throwaway data
/// store. When the cookie that marks success appears (the clearance
/// cookie, or the site's login cookie), every cookie the site set is
/// handed back with the web view's User-Agent, which the clearance is
/// bound to, and the sheet closes itself. Nothing the page renders reaches
/// the app's own views.
@MainActor
final class ChallengeSheetController: NSObject, WKNavigationDelegate, WKHTTPCookieStoreObserver {

    enum Failure: Error, LocalizedError {
        case cancelled
        case loadFailed(String)

        var errorDescription: String? {
            switch self {
            case .cancelled: "The window was closed before it finished."
            case .loadFailed(let message): "The page did not load: \(message)"
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
    }

    /// Show the check for `url` on the main window and wait for it to pass.
    static func present(source: String, url: URL) async throws -> SiteClearance {
        let controller = ChallengeSheetController(source: source, url: url, purpose: .humanCheck)
        return try await controller.run()
    }

    /// Show the site's sign-in page and wait for the user to sign in.
    static func presentSignIn(source: String, url: URL, loginCookiePrefix: String) async throws -> SiteClearance {
        let controller = ChallengeSheetController(source: source, url: url,
                                                  purpose: .signIn(loginCookiePrefix: loginCookiePrefix))
        return try await controller.run()
    }

    private let purpose: Purpose

    private let url: URL
    private let site: String
    private let sheet: NSWindow
    private let webView: WKWebView
    private var continuation: CheckedContinuation<SiteClearance, Error>?
    private var finished = false
    /// Keeps this controller alive while the sheet is up (the window holds
    /// no strong reference to its delegate).
    private var retained: ChallengeSheetController?

    private init(source: String, url: URL, purpose: Purpose) {
        self.url = url
        self.purpose = purpose
        let host = url.host ?? source
        site = host.hasPrefix("www.") ? String(host.dropFirst(4)) : host

        let config = WKWebViewConfiguration()
        config.websiteDataStore = WKWebsiteDataStore.nonPersistent()
        webView = WKWebView(frame: NSRect(x: 0, y: 0, width: 560, height: 480), configuration: config)
        webView.translatesAutoresizingMaskIntoConstraints = false

        sheet = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 600),
                         styleMask: [.titled], backing: .buffered, defer: false)
        let signingIn: Bool
        if case .signIn = purpose { signingIn = true } else { signingIn = false }
        sheet.title = signingIn ? "Sign in" : "Human check"
        super.init()

        let heading = NSTextField(wrappingLabelWithString: signingIn
            ? "Sign in to \(site) below. Your password goes only to \(site); the app keeps the session it gives back."
            : "\(site) is checking that you’re a person. Complete the check below to continue.")
        heading.font = MacFont.ui(13)
        heading.translatesAutoresizingMaskIntoConstraints = false

        let cancel = NSButton(title: "Cancel", target: self, action: #selector(cancelTapped))
        cancel.keyEquivalent = "\u{1b}"
        cancel.translatesAutoresizingMaskIntoConstraints = false

        let content = NSView()
        content.addSubview(heading)
        content.addSubview(webView)
        content.addSubview(cancel)
        NSLayoutConstraint.activate([
            heading.topAnchor.constraint(equalTo: content.topAnchor, constant: 20),
            heading.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 20),
            heading.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -20),
            webView.topAnchor.constraint(equalTo: heading.bottomAnchor, constant: 12),
            webView.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 20),
            webView.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -20),
            webView.heightAnchor.constraint(equalToConstant: 480),
            cancel.topAnchor.constraint(equalTo: webView.bottomAnchor, constant: 12),
            cancel.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -20),
            cancel.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -16),
        ])
        sheet.contentView = content

        webView.navigationDelegate = self
        webView.configuration.websiteDataStore.httpCookieStore.add(self)
    }

    private func run() async throws -> SiteClearance {
        retained = self
        return try await withCheckedThrowingContinuation { continuation in
            self.continuation = continuation
            if let host = Self.hostWindow {
                host.beginSheet(sheet)
            } else {
                sheet.center()
                sheet.makeKeyAndOrderFront(nil)
            }
            webView.load(URLRequest(url: url))
        }
    }

    /// The window the sheet hangs off: the key window if it's one of ours,
    /// else the main library window.
    private static var hostWindow: NSWindow? {
        if let key = NSApp.keyWindow, key.isVisible, key.sheetParent == nil, key.attachedSheet == nil {
            return key
        }
        return NSApp.windows.first { $0.isVisible && $0.windowController is MainWindowController }
    }

    @objc private func cancelTapped() {
        finish(.failure(Failure.cancelled))
    }

    // MARK: - Passing the check

    /// The check sets its cookie and reloads the page; either event lands
    /// here. Done once the clearance cookie is present.
    private func checkForClearance() {
        guard !finished else { return }
        webView.configuration.websiteDataStore.httpCookieStore.getAllCookies { [weak self] cookies in
            guard let self, !self.finished else { return }
            let ours = cookies.filter { Self.belongs($0.domain, to: self.site) }
            guard self.purpose.isDone(ours) else { return }
            self.webView.evaluateJavaScript("navigator.userAgent") { [weak self] result, _ in
                guard let self, !self.finished else { return }
                let userAgent = (result as? String) ?? ""
                self.finish(.success(SiteClearance(
                    cookies: ours.map { "\($0.name)=\($0.value)" },
                    userAgent: userAgent)))
            }
        }
    }

    /// Cookie domains come as "www.site.com" or ".site.com".
    private static func belongs(_ domain: String, to site: String) -> Bool {
        let bare = domain.hasPrefix(".") ? String(domain.dropFirst()) : domain
        return bare == site || bare.hasSuffix("." + site)
    }

    nonisolated func cookiesDidChange(in cookieStore: WKHTTPCookieStore) {
        Task { @MainActor in self.checkForClearance() }
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        checkForClearance()
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        // Submitting the sign-in form cancels the page load under it.
        if (error as NSError).code == NSURLErrorCancelled { return }
        finish(.failure(Failure.loadFailed(error.localizedDescription)))
    }

    // MARK: - Teardown

    private func finish(_ result: Result<SiteClearance, Error>) {
        guard !finished else { return }
        finished = true
        webView.stopLoading()
        webView.navigationDelegate = nil
        webView.configuration.websiteDataStore.httpCookieStore.remove(self)
        if let parent = sheet.sheetParent {
            parent.endSheet(sheet)
        }
        sheet.orderOut(nil)
        continuation?.resume(with: result)
        continuation = nil
        retained = nil
    }
}
