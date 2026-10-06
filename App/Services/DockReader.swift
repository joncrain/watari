import AppKit
import Foundation
import WatariCore
import os.log

private let dockLog = Logger(subsystem: "app.watari.mac", category: "DockReader")

/// Read the local Mac’s Dock layout (`com.apple.dock` `persistent-apps`).
///
/// Sandboxed Watari cannot rely on `UserDefaults(suiteName:)` alone — that
/// domain is opaque without a shared-preference temporary exception. We also
/// read `~/Library/Preferences/com.apple.dock.plist` via a home-relative
/// path exception so Listen always has a Dock layout to put on the wire.
enum DockReader {
    /// Current persistent Dock apps (empty when unreadable).
    static func currentApps() -> [DockAppOffer] {
        if let apps = appsFromUserDefaults(), !apps.isEmpty {
            dockLog.info("Dock via UserDefaults: \(apps.count, privacy: .public) app(s)")
            return apps
        }
        if let apps = appsFromPlist(), !apps.isEmpty {
            dockLog.info("Dock via plist: \(apps.count, privacy: .public) app(s)")
            return apps
        }
        dockLog.error("Dock layout unreadable (UserDefaults + plist empty)")
        return []
    }

    private static func appsFromUserDefaults() -> [DockAppOffer]? {
        guard
            let dock = UserDefaults(suiteName: "com.apple.dock"),
            let array = dock.array(forKey: "persistent-apps") as? [[String: Any]]
        else { return nil }
        return array.compactMap(parseEntry(_:))
    }

    private static func appsFromPlist() -> [DockAppOffer]? {
        let url = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Preferences/com.apple.dock.plist")
        guard FileManager.default.fileExists(atPath: url.path) else {
            dockLog.error("Dock plist missing at \(url.path, privacy: .public)")
            return nil
        }
        do {
            let data = try Data(contentsOf: url)
            guard
                let plist = try PropertyListSerialization.propertyList(from: data, options: [], format: nil)
                    as? [String: Any],
                let array = plist["persistent-apps"] as? [[String: Any]]
            else {
                dockLog.error("Dock plist missing persistent-apps")
                return nil
            }
            return array.compactMap(parseEntry(_:))
        } catch {
            dockLog.error("Dock plist read failed: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    private static func parseEntry(_ entry: [String: Any]) -> DockAppOffer? {
        guard let tileData = entry["tile-data"] as? [String: Any] else { return nil }

        if let fileData = tileData["file-data"] as? [String: Any],
           let urlString = fileData["_CFURLString"] as? String,
           let url = URL(string: urlString),
           url.isFileURL {
            let path = url.path
            let label = (tileData["file-label"] as? String)
                ?? URL(fileURLWithPath: path).deletingPathExtension().lastPathComponent
            return DockAppOffer(bundlePath: path, displayName: label)
        }

        // Some Dock entries only carry a bookmark; resolve when possible.
        if let book = tileData["book"] as? Data {
            var stale = false
            if let url = try? URL(
                resolvingBookmarkData: book,
                options: [.withoutUI, .withoutMounting],
                relativeTo: nil,
                bookmarkDataIsStale: &stale
            ), url.isFileURL {
                let path = url.path
                let label = (tileData["file-label"] as? String)
                    ?? url.deletingPathExtension().lastPathComponent
                return DockAppOffer(bundlePath: path, displayName: label)
            }
        }

        return nil
    }
}
