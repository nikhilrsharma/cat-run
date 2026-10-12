import AppKit
import Foundation

/// Performs the duplicate-launch check before any window, timer, or status item exists.
enum SingleInstance {
    struct Candidate {
        let processIdentifier: pid_t
        let finishedLaunching: Bool
        let launchDate: Date?
    }

    /// A completed launch wins over a new launch. Concurrent new launches use a
    /// stable PID order so they do not both redirect to each other and exit.
    static func preferredProcessIdentifier(in candidates: [Candidate]) -> pid_t? {
        candidates.min { left, right in
            if left.finishedLaunching != right.finishedLaunching {
                return left.finishedLaunching
            }
            if left.finishedLaunching {
                let leftDate = left.launchDate ?? .distantFuture
                let rightDate = right.launchDate ?? .distantFuture
                if leftDate != rightDate { return leftDate < rightDate }
            }
            return left.processIdentifier < right.processIdentifier
        }?.processIdentifier
    }

    /// Returns true when this launch should exit without constructing its delegate.
    @discardableResult
    static func redirectToRunningInstanceIfNeeded(
        bundleIdentifier: String? = Bundle.main.bundleIdentifier
    ) -> Bool {
        precondition(Thread.isMainThread)
        guard let bundleIdentifier else { return false }
        let current = NSRunningApplication.current
        var applications = NSRunningApplication.runningApplications(withBundleIdentifier: bundleIdentifier)
            .filter { !$0.isTerminated && $0.processIdentifier > 0 }
        if !applications.contains(where: { $0.isEqual(current) }) {
            applications.append(current)
        }
        let candidates = applications.map {
            Candidate(processIdentifier: $0.processIdentifier,
                      finishedLaunching: $0.isFinishedLaunching, launchDate: $0.launchDate)
        }
        guard let winner = preferredProcessIdentifier(in: candidates),
              winner != current.processIdentifier,
              let existing = applications.first(where: { $0.processIdentifier == winner }) else {
            return false
        }

        reopen(existing)
        return true
    }

    private static func reopen(_ existing: NSRunningApplication) {
        // Activation alone may leave an accessory app's closed window hidden.
        // Opening its exact running bundle also delivers the normal reopen event.
        _ = existing.activate(options: [.activateAllWindows])
        guard let bundleURL = existing.bundleURL else { return }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        configuration.createsNewApplicationInstance = false
        configuration.allowsRunningApplicationSubstitution = false
        configuration.addsToRecentItems = false
        configuration.promptsUserIfNeeded = false

        var completed = false
        NSWorkspace.shared.openApplication(at: bundleURL, configuration: configuration) { _, _ in
            DispatchQueue.main.async { completed = true }
        }

        // Let the asynchronous handoff finish before main returns. There is no
        // AppCoordinator here, so exiting cannot save settings or create a status item.
        let deadline = ProcessInfo.processInfo.systemUptime + 2
        while !completed {
            let remaining = deadline - ProcessInfo.processInfo.systemUptime
            guard remaining > 0 else { break }
            CFRunLoopRunInMode(.defaultMode, min(remaining, 0.05), true)
        }
    }
}
