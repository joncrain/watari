import Foundation

/// Job-level strategy when the same relative path exists and content hashes differ.
public enum ConflictPolicy: String, Codable, Sendable, Equatable, CaseIterable {
    /// Write beside the existing file with a non-colliding name (default).
    case keepBoth
    /// Overwrite the destination file.
    case update
    /// Leave the destination file alone.
    case skip

    public static let `default` = ConflictPolicy.keepBoth
}

/// Allocate a Finder-style "name 2.ext" path that is not in `taken`.
public enum KeepBothPath {
    public static func allocate(_ relativePath: String, taken: Set<String>) -> String {
        if !taken.contains(relativePath) { return relativePath }
        let ns = relativePath as NSString
        let ext = ns.pathExtension
        let base = ext.isEmpty ? relativePath : ns.deletingPathExtension
        var n = 2
        while true {
            let candidate: String
            if ext.isEmpty {
                candidate = "\(base) \(n)"
            } else {
                candidate = "\(base) \(n).\(ext)"
            }
            if !taken.contains(candidate) { return candidate }
            n += 1
        }
    }
}
