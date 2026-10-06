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
    private let homeBookmarkDefaultsKey = "watari.homeSecurityBookmark"
    private var homeAccessURL: URL?
    private var homeEntry: BookmarkEntry?

    var homeDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser
    }

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

    /// Convenience target: open panel starting at Documents / Desktop / Downloads (escape hatch only).
    func pickConvenience(_ target: ConvenienceTarget) -> URL? {
        pickFolder(startingAt: target.url)
    }

    /// Bookmark a standard home folder without an open panel.
    /// Uses active home scope (and a one-time home grant only if the sandbox requires it).
    func bookmarkHomeFolder(_ url: URL) throws -> BookmarkEntry {
        let home = homeDirectory.standardizedFileURL
        let target = url.standardizedFileURL
        guard isUnderHome(target) else {
            throw BookmarkError.notHomeFolder(target.path)
        }

        // Prefer direct bookmark (works with home-relative temporary exceptions / existing access).
        if let entry = try? save(url: target) {
            persistHomeBookmarkIfNeeded(from: home)
            return entry
        }

        try ensureHomeAccess()
        return try save(url: target)
    }

    /// One-time security-scoped grant for the user’s home directory (not per-folder pickers).
    func ensureHomeAccess() throws {
        if homeAccessURL != nil { return }

        if let restored = loadPersistedHomeBookmark() {
            do {
                let access = try startAccessRefreshing(restored)
                homeEntry = access.entry
                homeAccessURL = access.url
                return
            } catch {
                clearPersistedHomeBookmark()
            }
        }

        let home = homeDirectory
        guard let picked = pickFolder(
            startingAt: home,
            message: "Allow Watari to access your home folder once so you can choose what to transfer. Watari will not migrate Library or system data."
        ) else {
            throw BookmarkError.homeAccessCancelled
        }

        let standardized = picked.standardizedFileURL
        // Accept home itself or a parent that contains it (rare); reject unrelated picks.
        guard standardized.path == home.path
            || home.path.hasPrefix(standardized.path + "/")
            || isUnderHome(standardized)
        else {
            throw BookmarkError.homeAccessCancelled
        }

        let root = isUnderHome(standardized) && standardized.path != home.path
            ? home
            : standardized
        let entry = try save(url: root.path == home.path ? home : root)
        // If user picked a child by mistake, still try to scope home when accessible.
        let accessRoot: BookmarkEntry
        if entry.path == home.path {
            accessRoot = entry
        } else if let homeEntry = try? save(url: home) {
            accessRoot = homeEntry
        } else {
            accessRoot = entry
        }
        homeEntry = accessRoot
        homeAccessURL = try startAccess(to: accessRoot)
        persistHomeBookmark(accessRoot)
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

    private func isUnderHome(_ url: URL) -> Bool {
        let home = homeDirectory.standardizedFileURL.path
        let path = url.standardizedFileURL.path
        return path == home || path.hasPrefix(home + "/")
    }

    private func persistHomeBookmarkIfNeeded(from home: URL) {
        guard loadPersistedHomeBookmark() == nil else { return }
        if let entry = try? save(url: home) {
            persistHomeBookmark(entry)
        }
    }

    private func persistHomeBookmark(_ entry: BookmarkEntry) {
        UserDefaults.standard.set(entry.bookmarkData, forKey: homeBookmarkDefaultsKey)
        homeEntry = entry
    }

    private func loadPersistedHomeBookmark() -> BookmarkEntry? {
        guard let data = UserDefaults.standard.data(forKey: homeBookmarkDefaultsKey) else { return nil }
        return BookmarkEntry(
            id: "home",
            displayName: "Home",
            path: homeDirectory.path,
            bookmarkData: data
        )
    }

    private func clearPersistedHomeBookmark() {
        UserDefaults.standard.removeObject(forKey: homeBookmarkDefaultsKey)
        homeEntry = nil
    }
}

enum BookmarkError: LocalizedError {
    case accessDenied(String)
    case staleNeedsReselect(String)
    case reauthorizeCancelled(String)
    case homeAccessCancelled
    case notHomeFolder(String)

    var errorDescription: String? {
        switch self {
        case .accessDenied(let path):
            return "Could not start security-scoped access for \(path)"
        case .staleNeedsReselect(let path):
            return "Folder access expired for \(path). Use Re-authorize… on that folder."
        case .reauthorizeCancelled(let path):
            return "Re-authorize cancelled for \(path)"
        case .homeAccessCancelled:
            return "Home folder access is required once before selecting folders to transfer."
        case .notHomeFolder(let path):
            return "“\(path)” is outside the home folder."
        }
    }
}
