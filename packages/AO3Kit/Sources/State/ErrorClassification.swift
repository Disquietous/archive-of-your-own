import Foundation

/// Typed views over the Rust layer's error variants, replacing the magic
/// strings ("cancelled", "session_expired", "password_needed") the UI used
/// to match on. String fallbacks remain for Swift-native errors (Task
/// cancellation) and messages composed above the FFI layer.
extension Error {
    /// The operation was cancelled — by the user, a Task, or the Rust layer.
    var isCancellation: Bool {
        if self is CancellationError { return true }
        if case .Cancelled = self as? Ao3Error { return true }
        return "\(self)".lowercased().contains("cancelled")
    }

    /// AO3 rejected the session cookie mid-operation.
    var isSessionExpired: Bool {
        if case .SessionExpired = self as? Ao3Error { return true }
        return "\(self)".contains("session_expired")
    }

    /// No usable session and no way to restore one without the password —
    /// the UI must prompt for re-authentication.
    var isPasswordNeeded: Bool {
        if case .PasswordNeeded = self as? Ao3Error { return true }
        return "\(self)".contains("password_needed")
    }
}
