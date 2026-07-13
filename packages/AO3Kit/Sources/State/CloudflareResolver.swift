import Foundation
import Network
import WebKit

/// Resolves Cloudflare challenges by loading AO3 in a hidden WKWebView routed
/// through the local Tor SOCKS5 proxy. Uses iOS 17+ ProxyConfiguration APIs
/// to direct WKWebView traffic through our proxy so the cf_clearance cookie
/// is bound to the Tor exit node's IP.
///
/// Flow:
/// 1. Configure WKWebView with SOCKSv5 proxy pointing at our local Tor port.
/// 2. Load the AO3 homepage. WebKit's JavaScript engine handles any
///    Cloudflare Managed Challenge automatically.
/// 3. Once the page finishes loading (challenge passed), extract all AO3
///    cookies from the WKWebsiteDataStore.
/// 4. Return them to the caller for injection into the reqwest cookie jar.
@MainActor
final class CloudflareResolver: NSObject, WKNavigationDelegate {

    // MARK: - Types

    enum ResolveError: Error, LocalizedError {
        case noSocksPort
        case timeout
        case loadFailed(String)

        var errorDescription: String? {
            switch self {
            case .noSocksPort: return "SOCKS proxy not available"
            case .timeout: return "Cloudflare challenge timed out"
            case .loadFailed(let msg): return "Page load failed: \(msg)"
            }
        }
    }

    struct ResolvedCookies {
        /// All cookies for archiveofourown.org, as "name=value" strings.
        let cookies: [String]
        /// Whether a cf_clearance cookie was found.
        let hasCfClearance: Bool
    }

    // MARK: - State

    private var webView: WKWebView?
    private var continuation: CheckedContinuation<ResolvedCookies, Error>?
    private var timeoutTask: Task<Void, Never>?
    private var navigationRetries = 0
    private let maxRetries = 2

    /// How long to wait for the page + challenge to complete.
    private let challengeTimeout: TimeInterval = 45

    // MARK: - Public API

    /// Attempt to pass the Cloudflare challenge by loading AO3 in a hidden
    /// WKWebView routed through the given SOCKS port.
    ///
    /// Returns the resolved cookies, or throws on failure.
    func resolve(socksPort: UInt16) async throws -> ResolvedCookies {
        guard socksPort > 0 else { throw ResolveError.noSocksPort }

        return try await withCheckedThrowingContinuation { continuation in
            self.continuation = continuation
            self.navigationRetries = 0

            // Build proxy configuration using iOS 17+ Network framework
            let endpoint = NWEndpoint.hostPort(
                host: NWEndpoint.Host("127.0.0.1"),
                port: NWEndpoint.Port(integerLiteral: socksPort)
            )
            let proxyConfig = ProxyConfiguration(socksv5Proxy: endpoint)

            // Use a non-persistent data store so cookies don't leak across sessions
            let dataStore = WKWebsiteDataStore.nonPersistent()
            dataStore.proxyConfigurations = [proxyConfig]

            let config = WKWebViewConfiguration()
            config.websiteDataStore = dataStore

            let wv = WKWebView(frame: CGRect(x: 0, y: 0, width: 1, height: 1), configuration: config)
            wv.navigationDelegate = self
            // Keep the webView alive
            self.webView = wv

            // Start the timeout clock
            self.timeoutTask = Task { [weak self] in
                try? await Task.sleep(for: .seconds(self?.challengeTimeout ?? 45))
                guard !Task.isCancelled else { return }
                self?.handleTimeout()
            }

            // Load AO3 homepage
            let url = URL(string: "https://archiveofourown.org/")!
            wv.load(URLRequest(url: url))
        }
    }

    // MARK: - WKNavigationDelegate

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        // The page finished loading. This could be:
        // 1. The Cloudflare challenge page itself (which then redirects)
        // 2. The actual AO3 page (challenge passed)
        //
        // Check the page title or URL to determine which case we're in.
        // Cloudflare challenge pages have distinctive titles like "Just a moment..."
        webView.evaluateJavaScript("document.title") { [weak self] result, _ in
            guard let self else { return }
            let title = (result as? String) ?? ""

            if title.lowercased().contains("just a moment")
                || title.lowercased().contains("attention required")
                || title.lowercased().contains("checking") {
                // Still on the challenge page. Wait for the next navigation
                // (Cloudflare will auto-redirect after solving the challenge).
                return
            }

            // We appear to be past the challenge. Extract cookies.
            self.extractCookies()
        }
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        // Navigation failed (could be network error through Tor)
        if navigationRetries < maxRetries {
            navigationRetries += 1
            // Retry after a short delay
            Task {
                try? await Task.sleep(for: .seconds(2))
                let url = URL(string: "https://archiveofourown.org/")!
                webView.load(URLRequest(url: url))
            }
        } else {
            finishWith(.failure(ResolveError.loadFailed(error.localizedDescription)))
        }
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        // Provisional navigation failure (DNS, connection refused, etc.)
        if navigationRetries < maxRetries {
            navigationRetries += 1
            Task {
                try? await Task.sleep(for: .seconds(2))
                let url = URL(string: "https://archiveofourown.org/")!
                webView.load(URLRequest(url: url))
            }
        } else {
            finishWith(.failure(ResolveError.loadFailed(error.localizedDescription)))
        }
    }

    // MARK: - Cookie Extraction

    private func extractCookies() {
        guard let webView else {
            finishWith(.failure(ResolveError.loadFailed("WebView deallocated")))
            return
        }

        webView.configuration.websiteDataStore.httpCookieStore.getAllCookies { [weak self] cookies in
            guard let self else { return }

            let ao3Cookies = cookies.filter { cookie in
                cookie.domain.contains("archiveofourown.org")
            }

            let cookieStrings = ao3Cookies.map { "\($0.name)=\($0.value)" }
            let hasCf = ao3Cookies.contains { $0.name == "cf_clearance" }

            let resolved = ResolvedCookies(
                cookies: cookieStrings,
                hasCfClearance: hasCf
            )

            self.finishWith(.success(resolved))
        }
    }

    // MARK: - Lifecycle

    private func handleTimeout() {
        // Even on timeout, try to extract whatever cookies we have
        if webView != nil {
            extractCookies()
        } else {
            finishWith(.failure(ResolveError.timeout))
        }
    }

    private func finishWith(_ result: Result<ResolvedCookies, Error>) {
        timeoutTask?.cancel()
        timeoutTask = nil
        webView?.stopLoading()
        webView?.navigationDelegate = nil
        webView = nil

        if let continuation {
            self.continuation = nil
            continuation.resume(with: result)
        }
    }
}
