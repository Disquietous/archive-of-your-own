import AppKit

// Top-level code runs on the main thread before NSApplicationMain starts
// the run loop, so it is safe to assume main-actor isolation here.
let appDelegate = MainActor.assumeIsolated { AppDelegate() }
NSApplication.shared.delegate = appDelegate
_ = NSApplicationMain(CommandLine.argc, CommandLine.unsafeArgv)
