import AppKit
import Foundation

enum ConvenienceTarget: String, CaseIterable, Identifiable {
    case documents
    case desktop
    case downloads

    var id: String { rawValue }

    var title: String {
        switch self {
        case .documents: return "Documents"
        case .desktop: return "Desktop"
        case .downloads: return "Downloads"
        }
    }

    var searchPath: FileManager.SearchPathDirectory {
        switch self {
        case .documents: return .documentDirectory
        case .desktop: return .desktopDirectory
        case .downloads: return .downloadsDirectory
        }
    }

    var url: URL? {
        FileManager.default.urls(for: searchPath, in: .userDomainMask).first
    }
}

struct BookmarkAccess {
    var entry: BookmarkEntry
    var url: URL
    var didRefresh: Bool
}

/// Security-scoped bookmark storage for chosen folder roots.
final class BookmarkStore: @unchecked Sendable {
    func pickFolder(startingAt directory: URL? = nil, message: String? = nil) -> URL? {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.message = message
            ?? "Choose a folder for Watari to read. Watari will not follow symlinks outside this folder."
        panel.prompt = "Add Folder"
        if let directory {
            panel.directoryURL = directory
        }
        guard panel.runModal() == .OK else { return nil }
        return panel.url
    }

    /// Convenience target: open panel starting at Documents / Desktop / Downloads (sandbox grant still required).
    func pickConvenience(_ target: ConvenienceTarget) -> URL? {
        pickFolder(startingAt: target.url)
    }

    func save(url: URL, id: String = UUID().uuidString) throws -> BookmarkEntry {
        let data = try url.bookmarkData(
            options: [.withSecurityScope],
            includingResourceValuesForKeys: nil,
            relativeTo: nil
        )
        return BookmarkEntry(
            id: id,
            displayName: url.lastPathComponent,
            path: url.path,
            bookmarkData: data
        )
    }

    func resolve(_ entry: BookmarkEntry) throws -> (url: URL, isStale: Bool) {
        var isStale = false
        let url = try URL(
            resolvingBookmarkData: entry.bookmarkData,
            options: [.withSecurityScope],
            relativeTo: nil,
            bookmarkDataIsStale: &isStale
        )
        return (url, isStale)
    }

    /// Refresh bookmark bytes when the system marks them stale. Throws if re-authorize is required.
    func refreshIfStale(_ entry: BookmarkEntry) throws -> (entry: BookmarkEntry, didRefresh: Bool) {
        let resolved = try resolve(entry)
        guard resolved.isStale else { return (entry, false) }
        do {
            let refreshed = try save(url: resolved.url, id: entry.id)
            return (refreshed, true)
        } catch {
            throw BookmarkError.staleNeedsReselect(entry.path)
        }
    }

    /// Resolve, refresh stale bookmarks, then start security-scoped access.
    func startAccessRefreshing(_ entry: BookmarkEntry) throws -> BookmarkAccess {
        let refreshed = try refreshIfStale(entry)
        let url = try startAccess(to: refreshed.entry)
        return BookmarkAccess(entry: refreshed.entry, url: url, didRefresh: refreshed.didRefresh)
    }

    @discardableResult
    func startAccess(to entry: BookmarkEntry) throws -> URL {
        let resolved = try resolve(entry)
        guard resolved.url.startAccessingSecurityScopedResource() else {
            throw BookmarkError.accessDenied(entry.path)
        }
        return resolved.url
    }

    func stopAccess(to url: URL) {
        url.stopAccessingSecurityScopedResource()
    }

    /// Open panel so the user can re-grant access for a stale bookmark.
    func reauthorize(entry: BookmarkEntry) throws -> BookmarkEntry {
        let start = URL(fileURLWithPath: entry.path)
        guard let url = pickFolder(
            startingAt: start.deletingLastPathComponent(),
            message: "Watari’s access to “\(entry.displayName)” expired. Choose the folder again to continue."
        ) else {
            throw BookmarkError.reauthorizeCancelled(entry.path)
        }
        return try save(url: url, id: entry.id)
    }
}

enum BookmarkError: LocalizedError {
    case accessDenied(String)
    case staleNeedsReselect(String)
    case reauthorizeCancelled(String)

    var errorDescription: String? {
        switch self {
        case .accessDenied(let path):
            return "Could not start security-scoped access for \(path)"
        case .staleNeedsReselect(let path):
            return "Folder access expired for \(path). Use Re-authorize… on that folder."
        case .reauthorizeCancelled(let path):
            return "Re-authorize cancelled for \(path)"
        }
    }
}
