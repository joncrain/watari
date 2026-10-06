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

/// Security-scoped bookmark storage for chosen folder roots.
final class BookmarkStore: @unchecked Sendable {
    private let defaultsKey = "watari.folderBookmarks"

    func pickFolder(startingAt directory: URL? = nil) -> URL? {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.message = "Choose a folder for Watari to read. Watari will not follow symlinks outside this folder."
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

    func save(url: URL) throws -> BookmarkEntry {
        let data = try url.bookmarkData(
            options: [.withSecurityScope],
            includingResourceValuesForKeys: nil,
            relativeTo: nil
        )
        let entry = BookmarkEntry(
            id: UUID().uuidString,
            displayName: url.lastPathComponent,
            path: url.path,
            bookmarkData: data
        )
        return entry
    }

    func resolve(_ entry: BookmarkEntry) throws -> URL {
        var isStale = false
        let url = try URL(
            resolvingBookmarkData: entry.bookmarkData,
            options: [.withSecurityScope],
            relativeTo: nil,
            bookmarkDataIsStale: &isStale
        )
        if isStale {
            // Caller should re-save; still return resolved URL when possible.
        }
        return url
    }

    @discardableResult
    func startAccess(to entry: BookmarkEntry) throws -> URL {
        let url = try resolve(entry)
        guard url.startAccessingSecurityScopedResource() else {
            throw BookmarkError.accessDenied(entry.path)
        }
        return url
    }

    func stopAccess(to url: URL) {
        url.stopAccessingSecurityScopedResource()
    }
}

enum BookmarkError: LocalizedError {
    case accessDenied(String)

    var errorDescription: String? {
        switch self {
        case .accessDenied(let path):
            return "Could not start security-scoped access for \(path)"
        }
    }
}
