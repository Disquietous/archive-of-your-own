import Foundation

/// A launch in mock-archive mode: `--mock-archive` on the command line
/// (or AOYO_MOCK_ARCHIVE=1 in the environment). The app then runs against
/// the core's synthetic archive in a library of its own — a `mock`
/// folder beside the real one, with its own Keychain key, instance lock,
/// Tor state and logs — so a test session never touches the user's
/// library, and the two can even run side by side. iCloud sync is
/// refused in this mode.
///
///     open -n build/Debug/AoYO.app --args --mock-archive
///
/// In Xcode, add the argument to the scheme's Run action instead.
public enum MockLaunch {
    public nonisolated static let isActive: Bool = {
        let p = ProcessInfo.processInfo
        return p.arguments.contains("--mock-archive") || p.environment["AOYO_MOCK_ARCHIVE"] == "1"
    }()
}
