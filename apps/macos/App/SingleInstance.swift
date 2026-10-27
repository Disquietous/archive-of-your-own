import AppKit
import UserNotifications

/// One running instance per OS user. The authority is an exclusive `flock`
/// on a file beside the library, taken in main.swift before AppDelegate
/// (and so the database) exists: two instances writing one library would
/// each hold their own write-through caches and both push to iCloud as
/// owner. The kernel drops the lock when the process dies, crash included.
/// The lock lives in the user's home, so other users are unaffected.
enum SingleInstance {
    /// Posted by a duplicate launched from a notification click: the
    /// running instance brings What's New forward, as the click asked.
    static let showWhatsNewNotification = Notification.Name("com.archiveofyourown.reader.mac.showWhatsNew")

    /// Held open for the life of the process — closing it would release
    /// the lock.
    nonisolated(unsafe) private static var lockFD: Int32 = -1

    /// True when this process now owns the library; false when another
    /// instance already does.
    static func acquire() -> Bool {
        let dir = URL(fileURLWithPath: RustBridge.databasePath()).deletingLastPathComponent()
        let path = dir.appendingPathComponent("instance.lock").path
        let fd = open(path, O_CREAT | O_RDWR, 0o600)
        // No lock file (unwritable home): run rather than refuse to start.
        guard fd >= 0 else { return true }
        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else {
            close(fd)
            return false
        }
        lockFD = fd
        return true
    }
}

/// The whole life of a duplicate launch: no menu, no window, no library.
/// It hands focus to the running instance — and, when the launch was a
/// notification click, the What's New request — then quits.
@MainActor
final class DuplicateLaunchDelegate: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate {
    private var handedOff = false

    func applicationWillFinishLaunching(_ notification: Notification) {
        // The click's response is delivered once launch finishes; the
        // delegate has to be in place before then.
        UNUserNotificationCenter.current().delegate = self
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        let isDefaultLaunch = notification.userInfo?[NSApplication.launchIsDefaultUserInfoKey] as? Bool ?? true
        if isDefaultLaunch {
            handOff(showWhatsNew: false)
        } else {
            // A notification launch: wait briefly for its response, then go
            // regardless so a non-notification launch never lingers.
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
                self?.handOff(showWhatsNew: false)
            }
        }
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
                                            didReceive response: UNNotificationResponse,
                                            withCompletionHandler completionHandler: @escaping () -> Void) {
        completionHandler()
        Task { @MainActor [weak self] in self?.handOff(showWhatsNew: true) }
    }

    private func handOff(showWhatsNew: Bool) {
        guard !handedOff else { return }
        handedOff = true
        let me = NSRunningApplication.current
        let running = Bundle.main.bundleIdentifier.map {
            NSRunningApplication.runningApplications(withBundleIdentifier: $0)
        } ?? []
        if let primary = running.first(where: { $0.processIdentifier != me.processIdentifier }) {
            // This launch holds activation (the user just clicked); pass it
            // on — macOS 14 lets an app activate another only by yielding.
            NSApp.yieldActivation(to: primary)
            primary.activate()
        }
        if showWhatsNew {
            DistributedNotificationCenter.default().postNotificationName(
                SingleInstance.showWhatsNewNotification, object: nil, userInfo: nil, deliverImmediately: true)
        }
        NSApp.terminate(nil)
    }
}
