import Foundation
import LocalAuthentication
import Security

/// Opt-in "Unlock with Face ID" (M3). Off by default and only ever turned
/// on by the user in Settings › Privacy, after entering the database
/// password once. The password is then kept in the Keychain behind the
/// current biometric enrollment (`.biometryCurrentSet`, this device only,
/// never synced): enrolling a new face or finger invalidates it.
///
/// The password stays required after a device restart and after any wrong
/// password attempt, until the next successful password unlock. A failed or
/// cancelled biometric check is never a password attempt — it doesn't
/// count toward the wipe threshold.
enum BiometricUnlock {
    private static let service = "com.archiveofyourown.reader.biometric-unlock"
    private static let account = "library-password"
    private static let enabledKey = "biometricUnlockEnabled"
    private static let bootKey = "biometricUnlockBootTime"

    /// The user turned it on (and it hasn't been invalidated since).
    static var isEnabled: Bool {
        UserDefaults.standard.bool(forKey: enabledKey)
    }

    /// "Face ID", "Touch ID", "Optic ID" — nil when the device has no
    /// enrolled biometrics.
    static var biometryName: String? {
        let context = LAContext()
        guard context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: nil) else { return nil }
        switch context.biometryType {
        case .faceID: return "Face ID"
        case .touchID: return "Touch ID"
        case .opticID: return "Optic ID"
        default: return nil
        }
    }

    /// Store the (already verified) password behind biometrics. False when
    /// the Keychain refused — nothing is enabled then.
    static func enable(password: String) -> Bool {
        deleteItem()
        guard let access = SecAccessControlCreateWithFlags(
            nil, kSecAttrAccessibleWhenUnlockedThisDeviceOnly, .biometryCurrentSet, nil),
              let data = password.data(using: .utf8)
        else { return false }
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecAttrAccessControl as String: access,
            kSecAttrSynchronizable as String: false,
            kSecValueData as String: data,
        ]
        guard SecItemAdd(query as CFDictionary, nil) == errSecSuccess else { return false }
        UserDefaults.standard.set(true, forKey: enabledKey)
        noteSuccessfulPasswordUnlock()
        return true
    }

    /// Turn it off and delete the stored password.
    static func disable() {
        deleteItem()
        UserDefaults.standard.set(false, forKey: enabledKey)
        UserDefaults.standard.removeObject(forKey: bootKey)
    }

    /// Record the boot session a password unlock happened in: biometrics
    /// are only offered within that same session.
    static func noteSuccessfulPasswordUnlock() {
        guard let boot = bootTime() else { return }
        UserDefaults.standard.set(boot, forKey: bootKey)
    }

    /// Whether the unlock screen may offer biometrics now: enabled, the
    /// device still has biometrics, no wrong password since the last
    /// success, and no restart since the last password unlock.
    static func isAvailable(failedAttempts: Int) -> Bool {
        guard isEnabled, biometryName != nil, failedAttempts == 0,
              let boot = bootTime(),
              UserDefaults.standard.object(forKey: bootKey) as? Double == boot
        else { return false }
        return true
    }

    enum Outcome {
        case password(String)
        /// Cancelled or failed the check — fall back to typing, no count.
        case declined
        /// The stored item is gone (enrollment changed): now disabled.
        case invalidated
    }

    /// Ask for biometrics and read the stored password. Blocks while the
    /// system prompt is up, so call it off the main actor.
    static func readPassword(reason: String) -> Outcome {
        let context = LAContext()
        context.localizedReason = reason
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
            kSecUseAuthenticationContext as String: context,
        ]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        switch status {
        case errSecSuccess:
            guard let data = result as? Data, let password = String(data: data, encoding: .utf8)
            else { return .declined }
            return .password(password)
        case errSecItemNotFound:
            return .invalidated
        default:
            return .declined
        }
    }

    private static func deleteItem() {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(query as CFDictionary)
    }

    /// Kernel boot time (seconds since 1970) — changes on every restart.
    private static func bootTime() -> Double? {
        var tv = timeval()
        var size = MemoryLayout<timeval>.size
        var mib: [Int32] = [CTL_KERN, KERN_BOOTTIME]
        guard sysctl(&mib, 2, &tv, &size, nil, 0) == 0 else { return nil }
        return Double(tv.tv_sec) + Double(tv.tv_usec) / 1_000_000
    }
}
