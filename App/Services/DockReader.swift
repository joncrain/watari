import AppKit
import Foundation
import WatariCore

/// Read the local Mac’s Dock layout (`com.apple.dock` `persistent-apps`).
///
/// Genkan-style: round-trip through `UserDefaults(suiteName:)` rather than
/// editing the plist on disk, and project each tile to a portable
/// `DockAppOffer` for the offer catalog / destination preview.
enum DockReader {
    /// Current persistent Dock apps (empty when unreadable).
    static func currentApps() -> [DockAppOffer] {
        guard
            let dock = UserDefaults(suiteName: "com.apple.dock"),
            let array = dock.array(forKey: "persistent-apps") as? [[String: Any]]
        else { return [] }
        return array.compactMap(parseEntry(_:))
    }

    private static func parseEntry(_ entry: [String: Any]) -> DockAppOffer? {
        guard
            let tileData = entry["tile-data"] as? [String: Any],
            let fileData = tileData["file-data"] as? [String: Any],
            let urlString = fileData["_CFURLString"] as? String,
            let url = URL(string: urlString),
            url.isFileURL
        else { return nil }
        let path = url.path
        let label = (tileData["file-label"] as? String)
            ?? URL(fileURLWithPath: path).deletingPathExtension().lastPathComponent
        return DockAppOffer(bundlePath: path, displayName: label)
    }
}
