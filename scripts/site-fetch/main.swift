// site-fetch: a developer fetcher for sites behind a human check.
//
// Requests go out over URLSession with the saved clearance (cookies +
// the User-Agent they are bound to) for the URL's host. A 403 opens a
// WebKit window on the URL so the person can pass the check; the cookies
// the page sets and the web view's User-Agent are saved to the state
// file and the request is retried once. The state is reused until a
// request with it comes back 403 again.
//
// Usage: site-fetch [options] <url>
//   -o <file>            write the body to <file> (default: stdout)
//   -d <form-body>       POST this application/x-www-form-urlencoded body
//   -H 'Name: value'     extra request header (repeatable)
//   --state <file>       clearance state file (default: build/site-fetch/clearance.json)
//   --no-prompt          never open the check window; a 403 just fails
// Status, content type and byte count go to stderr.

import AppKit
import WebKit

struct Clearance: Codable {
    var cookies: [String]
    var userAgent: String
}

struct Options {
    var url: URL
    var output: String?
    var postBody: String?
    var headers: [(String, String)] = []
    var statePath: String
    var prompt = true
}

func fail(_ message: String) -> Never {
    FileHandle.standardError.write((message + "\n").data(using: .utf8)!)
    exit(1)
}

func parseOptions() -> Options {
    var args = Array(CommandLine.arguments.dropFirst())
    var url: URL?
    var output: String?
    var post: String?
    var headers: [(String, String)] = []
    var state = "build/site-fetch/clearance.json"
    var prompt = true
    while !args.isEmpty {
        let a = args.removeFirst()
        switch a {
        case "-o": output = args.isEmpty ? nil : args.removeFirst()
        case "-d": post = args.isEmpty ? nil : args.removeFirst()
        case "-H":
            guard !args.isEmpty else { fail("-H needs a value") }
            let raw = args.removeFirst()
            guard let colon = raw.firstIndex(of: ":") else { fail("header needs 'Name: value'") }
            headers.append((String(raw[..<colon]).trimmingCharacters(in: .whitespaces),
                            String(raw[raw.index(after: colon)...]).trimmingCharacters(in: .whitespaces)))
        case "--state": state = args.isEmpty ? state : args.removeFirst()
        case "--no-prompt": prompt = false
        default:
            if a.hasPrefix("-") { fail("unknown option \(a)") }
            url = URL(string: a)
        }
    }
    guard let url, url.host != nil else { fail("usage: site-fetch [-o file] [-d form] [-H 'N: v'] [--state file] [--no-prompt] <url>") }
    return Options(url: url, output: output, postBody: post, headers: headers, statePath: state, prompt: prompt)
}

/// Cookie domains come as "www.site.com" or ".site.com".
func belongs(_ domain: String, to site: String) -> Bool {
    let bare = domain.hasPrefix(".") ? String(domain.dropFirst()) : domain
    return bare == site || bare.hasSuffix("." + site)
}

func siteName(_ url: URL) -> String {
    let host = url.host ?? ""
    return host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
}

// MARK: - State (keyed by site)

func loadState(_ path: String) -> [String: Clearance] {
    guard let data = FileManager.default.contents(atPath: path),
          let state = try? JSONDecoder().decode([String: Clearance].self, from: data) else { return [:] }
    return state
}

func saveState(_ state: [String: Clearance], to path: String) {
    let dir = (path as NSString).deletingLastPathComponent
    try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    guard let data = try? encoder.encode(state) else { return }
    FileManager.default.createFile(atPath: path, contents: data, attributes: [.posixPermissions: 0o600])
}

// MARK: - Request

struct Reply {
    var status: Int
    var contentType: String
    var body: Data
}

func perform(_ opts: Options, clearance: Clearance?) -> Reply {
    var request = URLRequest(url: opts.url)
    request.cachePolicy = .reloadIgnoringLocalCacheData
    if let clearance {
        request.setValue(clearance.cookies.joined(separator: "; "), forHTTPHeaderField: "Cookie")
        request.setValue(clearance.userAgent, forHTTPHeaderField: "User-Agent")
    } else {
        request.setValue("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Safari/605.1.15",
                         forHTTPHeaderField: "User-Agent")
    }
    request.setValue("text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8", forHTTPHeaderField: "Accept")
    request.setValue("en-US,en;q=0.9", forHTTPHeaderField: "Accept-Language")
    if let body = opts.postBody {
        request.httpMethod = "POST"
        request.httpBody = body.data(using: .utf8)
        request.setValue("application/x-www-form-urlencoded; charset=UTF-8", forHTTPHeaderField: "Content-Type")
        request.setValue("XMLHttpRequest", forHTTPHeaderField: "X-Requested-With")
        request.setValue(opts.url.scheme! + "://" + opts.url.host!, forHTTPHeaderField: "Origin")
        request.setValue(opts.url.scheme! + "://" + opts.url.host! + "/", forHTTPHeaderField: "Referer")
    }
    for (name, value) in opts.headers { request.setValue(value, forHTTPHeaderField: name) }

    let config = URLSessionConfiguration.ephemeral
    config.httpShouldSetCookies = false
    config.httpCookieAcceptPolicy = .never
    let session = URLSession(configuration: config)
    let done = DispatchSemaphore(value: 0)
    var reply = Reply(status: 0, contentType: "", body: Data())
    var failure: Error?
    session.dataTask(with: request) { data, response, error in
        if let error { failure = error }
        if let http = response as? HTTPURLResponse {
            reply.status = http.statusCode
            reply.contentType = http.value(forHTTPHeaderField: "Content-Type") ?? ""
        }
        reply.body = data ?? Data()
        done.signal()
    }.resume()
    done.wait()
    if let failure { fail("request failed: \(failure.localizedDescription)") }
    return reply
}

// MARK: - The check window

@MainActor
final class ChallengeWindow: NSObject, WKNavigationDelegate, WKHTTPCookieStoreObserver {
    private let url: URL
    private let site: String
    private let window: NSWindow
    private let webView: WKWebView
    private let onDone: (Clearance?) -> Void
    private var finished = false

    init(url: URL, onDone: @escaping (Clearance?) -> Void) {
        self.url = url
        self.site = siteName(url)
        self.onDone = onDone
        let config = WKWebViewConfiguration()
        config.websiteDataStore = WKWebsiteDataStore.nonPersistent()
        webView = WKWebView(frame: NSRect(x: 0, y: 0, width: 640, height: 560), configuration: config)
        window = NSWindow(contentRect: webView.frame, styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "Human check — \(site)"
        window.contentView = webView
        super.init()
        webView.navigationDelegate = self
        webView.configuration.websiteDataStore.httpCookieStore.add(self)
        NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: window, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.finish(nil) }
        }
    }

    func show() {
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        webView.load(URLRequest(url: url))
    }

    private func check() {
        guard !finished else { return }
        webView.configuration.websiteDataStore.httpCookieStore.getAllCookies { [weak self] cookies in
            guard let self, !self.finished else { return }
            let ours = cookies.filter { belongs($0.domain, to: self.site) }
            guard ours.contains(where: { $0.name == "cf_clearance" }) else { return }
            self.webView.evaluateJavaScript("navigator.userAgent") { [weak self] result, _ in
                guard let self, !self.finished else { return }
                self.finish(Clearance(cookies: ours.map { "\($0.name)=\($0.value)" },
                                      userAgent: (result as? String) ?? ""))
            }
        }
    }

    nonisolated func cookiesDidChange(in cookieStore: WKHTTPCookieStore) {
        Task { @MainActor in self.check() }
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { check() }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        FileHandle.standardError.write("check page failed to load: \(error.localizedDescription)\n".data(using: .utf8)!)
        finish(nil)
    }

    private func finish(_ clearance: Clearance?) {
        guard !finished else { return }
        finished = true
        webView.stopLoading()
        webView.configuration.websiteDataStore.httpCookieStore.remove(self)
        window.orderOut(nil)
        onDone(clearance)
    }
}

/// Run the app loop until the check passes or the window is closed.
@MainActor
func earnClearance(for url: URL) -> Clearance? {
    let app = NSApplication.shared
    app.setActivationPolicy(.regular)
    var result: Clearance?
    var keep: ChallengeWindow?
    keep = ChallengeWindow(url: url) { clearance in
        result = clearance
        keep = nil
        app.stop(nil)
        // stop() takes effect after the next event; post one.
        app.postEvent(NSEvent.otherEvent(with: .applicationDefined, location: .zero, modifierFlags: [],
                                         timestamp: 0, windowNumber: 0, context: nil,
                                         subtype: 0, data1: 0, data2: 0)!, atStart: true)
    }
    keep?.show()
    app.run()
    return result
}

// MARK: - Main

let opts = parseOptions()
let site = siteName(opts.url)
var state = loadState(opts.statePath)
var reply = perform(opts, clearance: state[site])
var note = state[site] == nil ? "no saved clearance" : "saved clearance"

if reply.status == 403 && opts.prompt {
    FileHandle.standardError.write("403 from \(site) (\(note)); opening the human check…\n".data(using: .utf8)!)
    // The check must run on the page itself, not an ajax endpoint: use
    // the site root for a POST target, the URL itself otherwise.
    let checkURL = opts.postBody == nil ? opts.url : URL(string: opts.url.scheme! + "://" + opts.url.host! + "/")!
    if let earned = MainActor.assumeIsolated({ earnClearance(for: checkURL) }) {
        state[site] = earned
        saveState(state, to: opts.statePath)
        note = "fresh clearance"
        reply = perform(opts, clearance: earned)
    } else {
        fail("human check not completed")
    }
}

FileHandle.standardError.write("\(reply.status) \(reply.contentType) \(reply.body.count) bytes (\(note))\n".data(using: .utf8)!)
if let out = opts.output {
    let dir = (out as NSString).deletingLastPathComponent
    if !dir.isEmpty { try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true) }
    FileManager.default.createFile(atPath: out, contents: reply.body)
} else {
    FileHandle.standardOutput.write(reply.body)
}
exit(reply.status >= 200 && reply.status < 400 ? 0 : 2)
