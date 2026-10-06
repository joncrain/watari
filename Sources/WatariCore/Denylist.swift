import Foundation

/// Paths Watari refuses to copy even when they sit inside a selected folder.
public struct Denylist: Sendable, Equatable {
    public var extraPathSuffixes: [String]

    public init(extraPathSuffixes: [String] = []) {
        self.extraPathSuffixes = extraPathSuffixes
    }

    /// Built-in suffixes relative to any root (normalized, case-sensitive match on path components).
    public static let builtInSuffixes: [String] = [
        "Library/Keychains",
        "Library/Keychains/",
        "login.keychain-db",
        "metadata.keychain-db",
        "Library/Application Support/com.apple.TCC/TCC.db",
        "Library/Application Support/com.apple.TCC",
        "/Library/Managed Preferences",
        "Library/Managed Preferences",
        "/Library/ConfigurationProfiles",
        "Library/ConfigurationProfiles",
        ".mobileconfig",
    ]

    public func blocks(relativePath: String) -> Bool {
        let normalized = Self.normalize(relativePath)
        let lowered = normalized.lowercased()

        for suffix in Self.builtInSuffixes + extraPathSuffixes {
            let s = Self.normalize(suffix)
            if s.hasPrefix(".") {
                // extension-style deny
                if lowered.hasSuffix(s.lowercased()) { return true }
                continue
            }
            if normalized == s
                || normalized.hasSuffix("/" + s)
                || normalized.contains("/" + s + "/")
                || normalized.hasPrefix(s + "/")
            {
                return true
            }
            // basename match for keychain files
            if normalized.split(separator: "/").map(String.init).contains(where: { $0 == s || $0.hasSuffix(s) }) {
                if s.contains("keychain") || s.hasSuffix(".db") || s.hasSuffix(".mobileconfig") {
                    return true
                }
            }
        }

        // Explicit component checks
        let parts = normalized.split(separator: "/").map(String.init)
        if parts.contains("Keychains") { return true }
        if parts.contains(where: { $0.hasSuffix(".keychain-db") || $0.hasSuffix(".keychain") }) {
            return true
        }
        if parts.contains("TCC.db") { return true }
        if parts.contains("Managed Preferences") { return true }
        if parts.contains("ConfigurationProfiles") { return true }
        if parts.contains(where: { $0.hasSuffix(".mobileconfig") }) { return true }

        return false
    }

    public func warningForSelectingLibraryRoot(_ absolutePath: String) -> String? {
        let ns = (absolutePath as NSString).standardizingPath
        if ns == "/Library" || ns.hasSuffix("/Library") {
            return "Selecting Library is not system migration. Watari will still skip keychains, TCC, and configuration profiles."
        }
        return nil
    }

    private static func normalize(_ path: String) -> String {
        var p = path.replacingOccurrences(of: "\\", with: "/")
        while p.hasPrefix("./") { p.removeFirst(2) }
        while p.hasPrefix("/") { p.removeFirst() }
        while p.hasSuffix("/") && p.count > 1 { p.removeLast() }
        return p
    }
}
