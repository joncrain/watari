import AppKit
import Foundation
import WatariCore
import os.log

private let dockApplyLog = Logger(subsystem: "app.watari.mac", category: "DockApplier")

/// Apply a source Dock layout onto this Mac (Genkan-style).
///
/// Writes `com.apple.dock` `persistent-apps`, flushes cfprefsd, and
/// restarts Dock. Requires the shared-preference read-write temporary
/// exception for `com.apple.dock`.
enum DockApplier {
    /// Replace this Mac’s Dock apps with `apps` from the source catalog.
    /// Returns the number of tiles written, or throws when prefs are unavailable.
    @discardableResult
    static func apply(apps: [DockAppOffer]) throws -> Int {
        guard let dock = UserDefaults(suiteName: "com.apple.dock") else {
            throw DockApplyError.prefsUnavailable
        }
        let entries = apps.map(dockEntry(for:))
        dockApplyLog.info("Applying Dock layout: \(entries.count, privacy: .public) app(s)")
        dock.set(entries, forKey: "persistent-apps")
        dock.synchronize()
        forceCFPrefsdFlush()
        if let verify = UserDefaults(suiteName: "com.apple.dock"),
           let confirmed = verify.array(forKey: "persistent-apps") as? [[String: Any]] {
            dockApplyLog.info("cfprefsd confirms \(confirmed.count, privacy: .public) Dock entries")
        } else {
            dockApplyLog.error("Could not read back persistent-apps after write")
        }
        _ = restartDock()
        return entries.count
    }

    private static func dockEntry(for app: DockAppOffer) -> [String: Any] {
        let url = URL(fileURLWithPath: app.bundlePath, isDirectory: true)
        return [
            "tile-data": [
                "file-data": [
                    "_CFURLString": url.absoluteString,
                    "_CFURLStringType": 15,
                ],
                "file-label": app.displayName,
                "file-type": 41,
            ],
            "tile-type": "file-tile",
        ]
    }

    private static func forceCFPrefsdFlush() {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/defaults")
        process.arguments = ["read", "com.apple.dock", "persistent-apps"]
        process.standardOutput = Pipe()
        process.standardError = Pipe()
        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            dockApplyLog.error("defaults flush failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    @discardableResult
    private static func restartDock() -> Bool {
        let dockBundleID = "com.apple.dock"
        let preKillPids = Set(
            NSRunningApplication
                .runningApplications(withBundleIdentifier: dockBundleID)
                .map(\.processIdentifier)
        )
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/killall")
        process.arguments = ["Dock"]
        let killExit: Int32
        do {
            try process.run()
            process.waitUntilExit()
            killExit = process.terminationStatus
        } catch {
            dockApplyLog.error("killall Dock failed: \(error.localizedDescription, privacy: .public)")
            return false
        }

        let deadline = Date().addingTimeInterval(3.0)
        var newPid: pid_t = 0
        while Date() < deadline {
            let now = NSRunningApplication
                .runningApplications(withBundleIdentifier: dockBundleID)
                .map(\.processIdentifier)
            if let respawned = now.first(where: { !preKillPids.contains($0) }) {
                newPid = respawned
                break
            }
            Thread.sleep(forTimeInterval: 0.1)
        }
        if newPid > 0 {
            Thread.sleep(forTimeInterval: 1.0)
            dockApplyLog.info("Dock respawned pid=\(newPid, privacy: .public) killExit=\(killExit, privacy: .public)")
        } else {
            dockApplyLog.error("Dock did not respawn within 3s (killExit=\(killExit, privacy: .public))")
        }
        return killExit == 0 || killExit == 1
    }
}

enum DockApplyError: LocalizedError {
    case prefsUnavailable
    case emptyLayout

    var errorDescription: String? {
        switch self {
        case .prefsUnavailable:
            return "Couldn’t open Dock preferences on this Mac."
        case .emptyLayout:
            return "Source didn’t send a Dock layout to apply."
        }
    }
}
