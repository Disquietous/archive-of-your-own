import Foundation

/// What an archiveofourown.org URL points at, when it's something the apps
/// can open. Pure parsing — no network, no app state — so the iOS share
/// extension compiles this file on its own. Platform models route the
/// result to their screens (macOS "Open AO3 URL…" and drops, the iOS
/// share-extension hand-off).
enum AO3Link: Equatable {
    case work(id: String)
    /// `/works/{id}/chapters/{chapterID}` — both are AO3 ids; the chapter
    /// resolves to a chapter number against the work's saved chapters.
    case chapter(workID: String, chapterID: String)
    /// `/works/{id}?view_full_work=true`
    case entireWork(id: String)
    case user(name: String, pseud: String?, pane: UserPane)
    case series(id: String)
    case collection(name: String)
    case tag(name: String)

    enum UserPane: Equatable {
        /// The profile as the app opens it by default.
        case profile
        case works, bookmarks, collections
    }

    enum Rejection: Error, Equatable {
        /// Not a URL, or not archiveofourown.org.
        case notAO3
        /// An AO3 page the apps have no view for (comments, inbox, search
        /// pages, …).
        case unsupported

        var message: String {
            switch self {
            case .notAO3: "Not an AO3 link."
            case .unsupported: "This AO3 link isn’t supported yet."
            }
        }
    }

    /// One-line summary of what the apps open, for prompts and alerts.
    static let supportedSummary = "Works, chapters, authors, series, collections and tags can be opened."

    /// Classify a pasted, dropped or shared string. Accepts a bare URL,
    /// a URL without a scheme ("archiveofourown.org/works/1"), or text
    /// containing one (the first link found is used).
    static func classify(_ raw: String) -> Result<AO3Link, Rejection> {
        guard let url = url(in: raw) else { return .failure(.notAO3) }
        return classify(url)
    }

    static func classify(_ url: URL) -> Result<AO3Link, Rejection> {
        guard let host = url.host?.lowercased(),
              host == "archiveofourown.org" || host.hasSuffix(".archiveofourown.org")
        else { return .failure(.notAO3) }
        if let scheme = url.scheme?.lowercased(), scheme != "https", scheme != "http" {
            return .failure(.notAO3)
        }
        // `path` is percent-decoded; the fragment (#workskin) and query
        // (tracking, view_adult) are not part of it.
        let parts = url.path.split(separator: "/").map(String.init)
        guard let head = parts.first else { return .failure(.unsupported) }
        let link: AO3Link?
        switch head {
        case "works":
            link = workLink(parts, url: url)
        case "users":
            link = userLink(parts)
        case "series":
            link = parts.count == 2 && isID(parts[1]) ? .series(id: parts[1]) : nil
        case "collections":
            link = collectionLink(parts, url: url)
        case "tags":
            link = tagLink(parts)
        default:
            link = nil
        }
        return link.map { .success($0) } ?? .failure(.unsupported)
    }

    // MARK: - Path shapes

    private static func workLink(_ parts: [String], url: URL) -> AO3Link? {
        guard parts.count >= 2, isID(parts[1]) else { return nil }
        let id = parts[1]
        switch parts.count {
        case 2:
            return fullWorkRequested(url) ? .entireWork(id: id) : .work(id: id)
        case 3 where parts[2] == "navigate":
            return .work(id: id)
        case 4 where parts[2] == "chapters" && isID(parts[3]):
            return fullWorkRequested(url) ? .entireWork(id: id) : .chapter(workID: id, chapterID: parts[3])
        default:
            return nil
        }
    }

    private static func userLink(_ parts: [String]) -> AO3Link? {
        guard parts.count >= 2, !parts[1].isEmpty else { return nil }
        let name = parts[1]
        var rest = Array(parts.dropFirst(2))
        var pseud: String?
        if rest.first == "pseuds" {
            guard rest.count >= 2 else { return .user(name: name, pseud: nil, pane: .profile) }
            pseud = rest[1]
            rest = Array(rest.dropFirst(2))
        }
        let pane: UserPane
        switch rest.first {
        case nil, "profile", "series", "gifts": pane = .profile
        case "works": pane = .works
        case "bookmarks": pane = .bookmarks
        case "collections": pane = .collections
        default: return nil // inbox, readings, subscriptions, …
        }
        return .user(name: name, pseud: pseud, pane: pane)
    }

    private static func collectionLink(_ parts: [String], url: URL) -> AO3Link? {
        guard parts.count >= 2, !parts[1].isEmpty else { return nil }
        // A work shown inside a collection is still the work.
        if parts.count >= 4, parts[2] == "works" {
            return workLink(Array(parts.dropFirst(2)), url: url)
        }
        return .collection(name: parts[1])
    }

    private static func tagLink(_ parts: [String]) -> AO3Link? {
        guard parts.count == 2 || (parts.count == 3 && parts[2] == "works") else { return nil }
        let name = decodeTag(parts[1])
        return name.isEmpty ? nil : .tag(name: name)
    }

    // MARK: - Helpers

    private static func isID(_ s: String) -> Bool {
        !s.isEmpty && UInt64(s) != nil
    }

    private static func fullWorkRequested(_ url: URL) -> Bool {
        URLComponents(url: url, resolvingAgainstBaseURL: false)?
            .queryItems?.contains { $0.name == "view_full_work" && $0.value == "true" } ?? false
    }

    /// AO3 escapes characters that can't sit in a tag's path segment:
    /// `*s*` = "/", `*a*` = "&", `*d*` = ".", `*q*` = "?", `*h*` = "#".
    static func decodeTag(_ segment: String) -> String {
        segment
            .replacingOccurrences(of: "*s*", with: "/")
            .replacingOccurrences(of: "*a*", with: "&")
            .replacingOccurrences(of: "*d*", with: ".")
            .replacingOccurrences(of: "*q*", with: "?")
            .replacingOccurrences(of: "*h*", with: "#")
    }

    /// The URL a string holds: the whole string when it is one (a scheme
    /// is assumed when missing), else the first link inside the text.
    static func url(in raw: String) -> URL? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if !trimmed.contains(where: \.isWhitespace) {
            let candidate = trimmed.contains("://") ? trimmed : "https://\(trimmed)"
            if let url = URL(string: candidate), url.host != nil { return url }
        }
        guard let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue)
        else { return nil }
        let range = NSRange(trimmed.startIndex..., in: trimmed)
        return detector.firstMatch(in: trimmed, options: [], range: range)?.url
    }
}
