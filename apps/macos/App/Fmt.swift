import Foundation

enum Fmt {
    /// 8421 → "8.4k", 96230 → "96k"
    static func k(_ n: Int) -> String {
        guard n >= 1000 else { return "\(n)" }
        let v = Double(n) / 1000
        let s = n >= 10000 ? String(format: "%.0f", v) : String(format: "%.1f", v)
        return s.replacingOccurrences(of: ".0", with: "") + "k"
    }

    /// Epoch-seconds string → "2h ago" style relative time.
    static func relativeTime(_ epochString: String) -> String {
        guard let epoch = TimeInterval(epochString) else { return epochString }
        let date = Date(timeIntervalSince1970: epoch)
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter.localizedString(for: date, relativeTo: Date())
    }
}
