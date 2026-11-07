import Foundation
import Network

// MARK: - Privacy mode (the setting)

/// How requests are protected: the one rule the app enforces is that
/// nothing goes to AO3 unprotected unless the user chose `.open`.
/// Persisted in UserDefaults and mirrored into the core, which enforces it
/// before every request (design/private-transport-plan.md).
enum PrivacyModeSetting: String, CaseIterable {
    /// The app runs its own Tor client; requests wait for it or fail.
    case tor
    /// The user's VPN carries the default route; the core verifies the
    /// registered tunnel before every request.
    case vpn
    /// Direct, unprotected. An explicit opt-out.
    case open

    static let key = "privacyMode"
    /// The pre-mode setting: "Connect via Tor on launch". True was Tor,
    /// false was an unlabelled Open.
    static let legacyKey = "useTorByDefault"

    static var current: PrivacyModeSetting {
        get {
            let d = UserDefaults.standard
            if let raw = d.string(forKey: key), let mode = PrivacyModeSetting(rawValue: raw) { return mode }
            return d.bool(forKey: legacyKey) ? .tor : .open
        }
        set {
            let d = UserDefaults.standard
            d.set(newValue.rawValue, forKey: key)
            // Keep the legacy key in step for any reader not yet migrated.
            d.set(newValue == .tor, forKey: legacyKey)
        }
    }

    var core: PrivacyMode {
        switch self {
        case .tor: .tor
        case .vpn: .vpn
        case .open: .open
        }
    }

    var title: String {
        switch self {
        case .tor: "Tor"
        case .vpn: "My VPN"
        case .open: "None"
        }
    }

    /// Why a request was refused under this mode, when no live status is
    /// at hand.
    var refusalMessage: String {
        switch self {
        case .tor: "Tor isn’t connected, so nothing was sent."
        case .vpn: "Your VPN isn’t verified, so nothing was sent."
        case .open: "Nothing was sent."
        }
    }
}

/// VPN-mode settings that live beside the mode. The fingerprint is
/// device-specific (the library syncs between devices), so it is kept here
/// as the core's own JSON and pushed into the core at launch.
enum VpnSettings {
    static let requiredKey = "vpnRequired"
    static let fingerprintKey = "vpnFingerprint"

    /// Whether VPN mode refuses requests while the VPN is not verified.
    /// Default on; off makes VPN mode behave as Open with the status still shown.
    static var required: Bool {
        get { UserDefaults.standard.object(forKey: requiredKey) as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: requiredKey) }
    }

    static var fingerprintJSON: String? {
        get { UserDefaults.standard.string(forKey: fingerprintKey) }
        set { UserDefaults.standard.set(newValue, forKey: fingerprintKey) }
    }
}

// MARK: - Privacy status (what the UI shows)

/// One status for the pill, popover, banner and settings, whatever the
/// mode. Folds the Tor connection state and the VPN verification together.
enum PrivacyStatus: Equatable {
    case tor(TorStatus)
    case vpn(VpnStatus, label: String?)
    case open

    /// Requests can go out protected right now (or the user opted out).
    var isProtected: Bool {
        switch self {
        case .tor(let status): status.isConnected
        case .vpn(let status, _): status == .matched
        case .open: false
        }
    }

    var title: String {
        switch self {
        case .tor(let status):
            return status.isConnected ? "Connected through Tor" : "Tor not connected"
        case .vpn(let status, let label):
            let name = label ?? "your VPN"
            switch status {
            case .matched: return "Protected by \(name)"
            case .noTunnel: return "\(name) is off"
            case .differentTunnel: return "A different VPN is active"
            case .notRegistered: return "No VPN registered"
            case .unknown: return "VPN state unknown"
            }
        case .open:
            return "Not private"
        }
    }

    /// SF Symbol for the pill and shield.
    var icon: String {
        switch self {
        case .open: "shield.slash"
        default: isProtected ? "checkmark.shield" : "xmark.shield"
        }
    }

    /// Short instruction for a control that waits on protection.
    var connectHint: String {
        switch self {
        case .tor: "Connect to Tor first"
        case .vpn(_, let label): "Connect \(label ?? "your VPN") first"
        case .open: ""
        }
    }

    /// How a request travels, for confirmation copy ("sent over Tor").
    var transportPhrase: String {
        switch self {
        case .tor: "sent over Tor"
        case .vpn(_, let label): "sent through \(label ?? "your VPN")"
        case .open: "sent over a direct, unprotected connection"
        }
    }

    /// Why a request was refused, for error text.
    var refusalMessage: String {
        switch self {
        case .tor: "Tor isn’t connected, so nothing was sent."
        case .vpn(_, let label): "\(label ?? "Your VPN") isn’t verified, so nothing was sent."
        case .open: "Nothing was sent."
        }
    }

    var subtitle: String {
        switch self {
        case .tor(let status):
            switch status {
            case .connected: "Three relays between you and AO3."
            case .connecting: "Building a circuit…"
            case .disconnected: "Nothing is sent until Tor connects."
            case .error(let message): message
            }
        case .vpn(let status, _):
            switch status {
            case .matched: "Your traffic leaves through the registered tunnel."
            case .noTunnel: "Your traffic would go out directly. Connect the VPN."
            case .differentTunnel(let seen): "Traffic is going through \(seen)."
            case .notRegistered: "Register your VPN in Settings › Privacy while it is connected."
            case .unknown(let message): message
            }
        case .open:
            "AO3 and your network see your address directly."
        }
    }
}

extension PrivacyStatus {
    /// "Protected by NordVPN · checked 12:04:31", for the settings row.
    func titleWithCheck(at date: Date?) -> String {
        guard case .vpn = self, let date else { return title }
        return "\(title) · checked \(date.formatted(date: .omitted, time: .standard))"
    }
}

// MARK: - Network path watcher

/// Tells the core when the system's network path changes so VPN
/// verification re-runs without waiting for the next request. One per
/// bridge; the handler is called on the main queue.
final class NetworkPathWatcher {
    private let monitor = NWPathMonitor()
    private let queue = DispatchQueue(label: "aoyo.network-path")

    init(onChange: @escaping @MainActor () -> Void) {
        monitor.pathUpdateHandler = { _ in
            DispatchQueue.main.async {
                MainActor.assumeIsolated { onChange() }
            }
        }
        monitor.start(queue: queue)
    }

    deinit {
        monitor.cancel()
    }
}
