import AppKit
import Foundation

enum TargetAppTracker {
    static func captureFrontmost() -> TargetApp? {
        guard let app = NSWorkspace.shared.frontmostApplication else {
            return nil
        }
        return TargetApp(
            bundleIdentifier: app.bundleIdentifier,
            processIdentifier: app.processIdentifier,
            localizedName: app.localizedName ?? "当前应用"
        )
    }

    @discardableResult
    static func activate(_ targetApp: TargetApp) -> Bool {
        if let running = NSRunningApplication(processIdentifier: targetApp.processIdentifier) {
            return running.activate(options: [.activateIgnoringOtherApps])
        }

        if let bundleIdentifier = targetApp.bundleIdentifier {
            let matching = NSRunningApplication.runningApplications(withBundleIdentifier: bundleIdentifier)
            if let first = matching.first {
                return first.activate(options: [.activateIgnoringOtherApps])
            }
        }

        return false
    }
}
