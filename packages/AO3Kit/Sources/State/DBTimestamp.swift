import Foundation

/// The database's single timestamp encoding: UTC "YYYY-MM-DD HH:MM:SS"
/// (SQLite `datetime('now')` text). Legacy epoch-seconds strings from
/// pre-migration rows still parse during the transition.
enum DBTimestamp {
    private static let formatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm:ss"
        f.timeZone = TimeZone(identifier: "UTC")
        f.locale = Locale(identifier: "en_US_POSIX")
        return f
    }()

    static func date(_ s: String) -> Date? {
        if let epoch = TimeInterval(s) { return Date(timeIntervalSince1970: epoch) }
        return formatter.date(from: s)
    }

    /// "3d ago"-style relative rendering, or nil for empty/unparseable input.
    static func relative(_ s: String) -> String? {
        guard !s.isEmpty, let date = date(s) else { return nil }
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .abbreviated
        return f.localizedString(for: date, relativeTo: Date())
    }
}
