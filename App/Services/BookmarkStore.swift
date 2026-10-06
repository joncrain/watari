import AppKit
import Foundation
import os.log

private let log = Logger(subsystem: "app.watari.mac", category: "BookmarkStore")

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
    /// Whitelist folder names covered by home-relative temporary-exception entitlements.
    static let whitelistedHomeFolderNames: Set<String> = [
        "Desktop", "Documents", "Downloads", "Pictures", "Movies", "Music", "Public",
    ]

    /// Real user home (`/Users/<name>`), not the App Sandbox container home.
    ///
    /// `FileManager.homeDirectoryForCurrentUser` returns
    /// `~/Library/Containers/app.watari.mac/Data` inside the sandbox, which
    /// made whitelist offers resolve to container stubs (only Documents was
    /// listable) instead of the user’s real Desktop/Documents/….
    /// Home-relative temporary-exception entitlements apply to the real home.
    var homeDirectory: URL {
        if let pw = getpwuid(getuid()), let dir = pw.pointee.pw_dir {
            return URL(fileURLWithPath: String(cString: dir), isDirectory: true)
                .standardizedFileURL
        }
        return FileManager.default.homeDirectoryForCurrentUser.standardizedFileURL
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

    /// Offer a standard whitelist home folder without an open panel.
    ///
    /// Always uses `.homeRelativeException` (never a security-scoped bookmark).
    /// Creating `withSecurityScope` bookmarks without a user open-panel grant
    /// can “succeed” at bootstrap, then fail later in
    /// `startAccessingSecurityScopedResource()` — which dropped Desktop /
    /// Downloads / etc. from the offer catalog and left only Documents when
    /// TCC happened to allow that one path.
    func bookmarkWhitelistedFolder(_ url: URL) throws -> BookmarkEntry {
        let target = url.standardizedFileURL
        let name = target.lastPathComponent
        guard Self.whitelistedHomeFolderNames.contains(name), isUnderHome(target) else {
            throw BookmarkError.notWhitelisted(name)
        }

        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: target.path, isDirectory: &isDir), isDir.boolValue else {
            log.error("Whitelist folder missing: \(target.path, privacy: .public)")
            throw BookmarkError.missingFolder(name)
        }

        // Soft probe — existence is enough to offer; listing may still work via
        // the home-relative temporary exception when Listen serves the catalog.
        do {
            _ = try FileManager.default.contentsOfDirectory(
                at: target,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles]
            )
            log.info("Whitelist offer \(name, privacy: .public) via home-relative temporary exception")
        } catch {
            log.info(
                "Whitelist offer \(name, privacy: .public) (exists; list probe: \(error.localizedDescription, privacy: .public))"
            )
        }

        return BookmarkEntry(
            id: UUID().uuidString,
            displayName: name,
            path: target.path,
            bookmarkData: Data(),
            access: .homeRelativeException
        )
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
            path: url.standardizedFileURL.path,
            bookmarkData: data,
            access: .securityScoped
        )
    }

    func resolve(_ entry: BookmarkEntry) throws -> (url: URL, isStale: Bool) {
        switch entry.access {
        case .homeRelativeException:
            return (URL(fileURLWithPath: entry.path, isDirectory: true), false)
        case .securityScoped:
            var isStale = false
            let url = try URL(
                resolvingBookmarkData: entry.bookmarkData,
                options: [.withSecurityScope],
                relativeTo: nil,
                bookmarkDataIsStale: &isStale
            )
            return (url, isStale)
        }
    }

    /// Refresh bookmark bytes when the system marks them stale. Throws if re-authorize is required.
    func refreshIfStale(_ entry: BookmarkEntry) throws -> (entry: BookmarkEntry, didRefresh: Bool) {
        switch entry.access {
        case .homeRelativeException:
            return (entry, false)
        case .securityScoped:
            let resolved = try resolve(entry)
            guard resolved.isStale else { return (entry, false) }
            do {
                let refreshed = try save(url: resolved.url, id: entry.id)
                return (refreshed, true)
            } catch {
                throw BookmarkError.staleNeedsReselect(entry.path)
            }
        }
    }

    /// Resolve, refresh stale bookmarks, then start security-scoped access (or exception path).
    func startAccessRefreshing(_ entry: BookmarkEntry) throws -> BookmarkAccess {
        let refreshed = try refreshIfStale(entry)
        let url = try startAccess(to: refreshed.entry)
        return BookmarkAccess(entry: refreshed.entry, url: url, didRefresh: refreshed.didRefresh)
    }

    @discardableResult
    func startAccess(to entry: BookmarkEntry) throws -> URL {
        switch entry.access {
        case .homeRelativeException:
            let url = URL(fileURLWithPath: entry.path, isDirectory: true).standardizedFileURL
            var isDir: ObjCBool = false
            guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir), isDir.boolValue else {
                throw BookmarkError.missingFolder(entry.displayName)
            }
            // Prefer confirming list access, but still return the URL when the
            // folder exists — temporary-exception reads may succeed on later
            // FileScanner even if this soft probe is noisy under TCC.
            do {
                _ = try FileManager.default.contentsOfDirectory(
                    at: url,
                    includingPropertiesForKeys: nil,
                    options: [.skipsHiddenFiles]
                )
            } catch {
                log.info(
                    "Exception list probe for \(url.path, privacy: .public): \(error.localizedDescription, privacy: .public) — offering anyway"
                )
            }
            return url
        case .securityScoped:
            let resolved = try resolve(entry)
            guard resolved.url.startAccessingSecurityScopedResource() else {
                log.error("startAccessingSecurityScopedResource failed for \(entry.path, privacy: .public)")
                throw BookmarkError.accessDenied(entry.path)
            }
            return resolved.url
        }
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

    private func makeVerifiedSecurityScopedEntry(for url: URL) throws -> BookmarkEntry {
        let entry = try save(url: url)
        let accessURL = try startAccess(to: entry)
        stopAccess(to: accessURL)
        return entry
    }

    private func isUnderHome(_ url: URL) -> Bool {
        let home = homeDirectory.path
        let path = url.standardizedFileURL.path
        return path == home || path.hasPrefix(home + "/")
    }
}

enum BookmarkError: LocalizedError {
    case accessDenied(String)
    case staleNeedsReselect(String)
    case reauthorizeCancelled(String)
    case missingFolder(String)
    case notWhitelisted(String)

    var errorDescription: String? {
        switch self {
        case .accessDenied(let path):
            return "Could not access \(path)"
        case .staleNeedsReselect(let path):
            return "Folder access expired for \(path). Use Re-authorize… on that folder."
        case .reauthorizeCancelled(let path):
            return "Re-authorize cancelled for \(path)"
        case .missingFolder(let name):
            return "“\(name)” isn’t available on this Mac."
        case .notWhitelisted(let name):
            return "“\(name)” isn’t in the default folder list. Use Add folder… instead."
        }
    }
}
