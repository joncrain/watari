import Foundation

/// Map source absolute roots onto the destination user’s home (same relative place).
///
/// Example: source `/Users/joncrain/Desktop` → destination `/Users/jon.crain/Desktop`
/// when each Mac’s home differs. Offer catalog paths carry the source absolute prefix;
/// we infer the source home and rewrite under `FileManager`’s current-user home.
public enum HomePathMapper {
    /// Infer `/Users/<name>` or `/home/<name>` from absolute folder paths.
    public static func inferUserHome(from paths: [String]) -> String? {
        let inferred = paths.compactMap(userHomePrefix(of:))
        guard !inferred.isEmpty else { return nil }
        var counts: [String: Int] = [:]
        for home in inferred {
            counts[home, default: 0] += 1
        }
        return counts.max(by: { $0.value < $1.value })?.key
    }

    /// `/Users/ada/Desktop` → `/Users/ada`; otherwise nil.
    public static func userHomePrefix(of absolutePath: String) -> String? {
        let standardized = (absolutePath as NSString).standardizingPath
        let parts = (standardized as NSString).pathComponents
        // ["/", "Users", "ada", ...]
        guard parts.count >= 3 else { return nil }
        let root = parts[1]
        guard root == "Users" || root == "home" else { return nil }
        return "/" + root + "/" + parts[2]
    }

    /// Path relative to `home`, or nil when `absolute` is not under that home.
    public static func relativePath(absolute: String, home: String) -> String? {
        let abs = (absolute as NSString).standardizingPath
        let homePath = (home as NSString).standardizingPath
        if abs == homePath { return "" }
        let prefix = homePath.hasSuffix("/") ? homePath : homePath + "/"
        guard abs.hasPrefix(prefix) else { return nil }
        return String(abs.dropFirst(prefix.count))
    }

    /// Destination folder URL for one offered source root.
    public static func mapRoot(
        sourceAbsolutePath: String,
        sourceHome: String?,
        destinationHome: URL
    ) -> URL {
        let destHome = destinationHome.standardizedFileURL
        if let sourceHome,
           let relative = relativePath(absolute: sourceAbsolutePath, home: sourceHome),
           !relative.isEmpty {
            return destHome.appendingPathComponent(relative, isDirectory: true)
        }
        let name = URL(fileURLWithPath: sourceAbsolutePath).standardizedFileURL.lastPathComponent
        return destHome.appendingPathComponent(name, isDirectory: true)
    }

    /// Display-name → destination root URL for a pull.
    ///
    /// - When `overrideParent` is set (advanced), roots land as `overrideParent/<name>/…`
    ///   (legacy single receive-folder behavior).
    /// - Otherwise each offer maps to the same place under `destinationHome` as under the
    ///   inferred source home.
    public static func destinationRoots(
        offers: [OfferedRoot],
        destinationHome: URL,
        overrideParent: URL? = nil
    ) -> [String: URL] {
        if let parent = overrideParent?.standardizedFileURL {
            return Dictionary(uniqueKeysWithValues: offers.map { offer in
                (offer.name, parent.appendingPathComponent(offer.name, isDirectory: true))
            })
        }
        let sourceHome = inferUserHome(from: offers.map(\.path))
        return Dictionary(uniqueKeysWithValues: offers.map { offer in
            (
                offer.name,
                mapRoot(
                    sourceAbsolutePath: offer.path,
                    sourceHome: sourceHome,
                    destinationHome: destinationHome
                )
            )
        })
    }

    /// Short UI lines: `Desktop → /Users/you/Desktop`.
    public static func mappingLabels(
        offers: [OfferedRoot],
        destinationHome: URL,
        overrideParent: URL? = nil
    ) -> [(name: String, destinationPath: String)] {
        let roots = destinationRoots(
            offers: offers,
            destinationHome: destinationHome,
            overrideParent: overrideParent
        )
        return offers.compactMap { offer in
            guard let url = roots[offer.name] else { return nil }
            return (offer.name, url.path)
        }
    }
}
