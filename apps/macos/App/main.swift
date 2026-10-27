import AppKit

// Top-level code runs on the main thread before NSApplicationMain starts
// the run loop, so it is safe to assume main-actor isolation here.
// The single-instance lock is taken first: AppDelegate's AppState can open
// the library during init, and a duplicate must never get that far.
let appDelegate: any NSApplicationDelegate = MainActor.assumeIsolated {
    if SingleInstance.acquire() {
        return AppDelegate() as any NSApplicationDelegate
    }
    return DuplicateLaunchDelegate() as any NSApplicationDelegate
}
NSApplication.shared.delegate = appDelegate
_ = NSApplicationMain(CommandLine.argc, CommandLine.unsafeArgv)
