import AppKit
import os

/// Process-wide "we are quitting" flag, readable from any thread.
enum AppLifecycle {
    private static let flag = OSAllocatedUnfairLock(initialState: false)

    static var isTerminating: Bool { flag.withLock { $0 } }

    static func markTerminating() { flag.withLock { $0 = true } }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        // Set before AppKit resolves outstanding drag promises during terminate.
        AppLifecycle.markTerminating()
        return .terminateNow
    }
}
