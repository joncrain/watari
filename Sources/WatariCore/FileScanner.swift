import Foundation

#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

/// Walk a selected root and capture portable metadata (size, owner, content hash).
public enum FileScanner {
    public struct Result: Sendable {
        public var entries: [FileMetadata]
        public var skipped: [(path: String, reason: SkipReason)]

        public init(entries: [FileMetadata] = [], skipped: [(path: String, reason: SkipReason)] = []) {
            self.entries = entries
            self.skipped = skipped
        }
    }

    /// Scan `root`. Relative paths are rooted at `displayRoot` (folder display name).
    public static func scan(
        root: URL,
        displayRoot: String,
        denylist: Denylist = Denylist(),
        hashContents: Bool = true
    ) throws -> Result {
        var entries: [FileMetadata] = []
        var skipped: [(path: String, reason: SkipReason)] = []
        let fm = FileManager.default

        entries.append(try metadata(for: root, relativePath: displayRoot, hashContents: false))

        guard let enumerator = fm.enumerator(
            at: root,
            includingPropertiesForKeys: [
                .isDirectoryKey,
                .isSymbolicLinkKey,
                .isRegularFileKey,
                .fileSizeKey,
                .contentModificationDateKey,
                .creationDateKey,
                .fileResourceTypeKey,
            ],
            options: [.skipsPackageDescendants]
        ) else {
            return Result(entries: entries, skipped: skipped)
        }

        for case let fileURL as URL in enumerator {
            let values: URLResourceValues
            do {
                values = try fileURL.resourceValues(forKeys: [
                    .isDirectoryKey,
                    .isSymbolicLinkKey,
                    .isRegularFileKey,
                    .fileSizeKey,
                    .contentModificationDateKey,
                    .creationDateKey,
                    .fileResourceTypeKey,
                ])
            } catch {
                skipped.append((relativePath(fileURL, root: root, displayRoot: displayRoot), .unreadable))
                continue
            }

            let rel = relativePath(fileURL, root: root, displayRoot: displayRoot)
            if denylist.blocks(relativePath: rel) {
                skipped.append((rel, .denylist))
                if values.isDirectory == true { enumerator.skipDescendants() }
                continue
            }

            if isSpecialFile(values) {
                skipped.append((rel, .specialFile))
                continue
            }

            let isSymlink = values.isSymbolicLink ?? false
            if isSymlink {
                let target = (try? fm.destinationOfSymbolicLink(atPath: fileURL.path)) ?? ""
                if symlinkEscapesSelection(target: target, root: root, linkURL: fileURL) {
                    skipped.append((rel, .symlinkOutsideSelection))
                    enumerator.skipDescendants()
                    continue
                }
                let owner = posixOwner(at: fileURL.path)
                entries.append(
                    FileMetadata(
                        relativePath: rel,
                        isDirectory: false,
                        isSymlink: true,
                        symlinkTarget: target,
                        size: 0,
                        mode: owner.mode,
                        uid: owner.uid,
                        gid: owner.gid,
                        ownerName: owner.ownerName,
                        groupName: owner.groupName,
                        modificationTime: values.contentModificationDate ?? Date(timeIntervalSince1970: 0),
                        creationTime: values.creationDate
                    )
                )
                enumerator.skipDescendants()
                continue
            }

            let isDir = values.isDirectory ?? false
            do {
                entries.append(
                    try metadata(
                        for: fileURL,
                        relativePath: rel,
                        values: values,
                        hashContents: hashContents && !isDir
                    )
                )
            } catch {
                skipped.append((rel, .unreadable))
            }
        }

        return Result(entries: entries, skipped: skipped)
    }

    private static func relativePath(_ fileURL: URL, root: URL, displayRoot: String) -> String {
        let rootPath = root.standardizedFileURL.path
        let filePath = fileURL.standardizedFileURL.path
        if filePath == rootPath { return displayRoot }
        let prefix = rootPath.hasSuffix("/") ? rootPath : rootPath + "/"
        if filePath.hasPrefix(prefix) {
            return displayRoot + "/" + String(filePath.dropFirst(prefix.count))
        }
        return displayRoot + "/" + fileURL.lastPathComponent
    }

    private static func metadata(
        for url: URL,
        relativePath: String,
        values: URLResourceValues? = nil,
        hashContents: Bool
    ) throws -> FileMetadata {
        let values = try values ?? url.resourceValues(forKeys: [
            .isDirectoryKey,
            .isSymbolicLinkKey,
            .fileSizeKey,
            .contentModificationDateKey,
            .creationDateKey,
        ])
        let isDir = values.isDirectory ?? false
        let isSymlink = values.isSymbolicLink ?? false
        var fingerprint: String?
        if hashContents, !isDir, !isSymlink {
            fingerprint = try ContentHash.sha256Hex(fileAt: url)
        }
        let owner = posixOwner(at: url.path)
        return FileMetadata(
            relativePath: relativePath,
            isDirectory: isDir,
            isSymlink: isSymlink,
            symlinkTarget: nil,
            size: UInt64(values.fileSize ?? 0),
            mode: owner.mode,
            uid: owner.uid,
            gid: owner.gid,
            ownerName: owner.ownerName,
            groupName: owner.groupName,
            modificationTime: values.contentModificationDate ?? Date(timeIntervalSince1970: 0),
            creationTime: values.creationDate,
            contentFingerprint: fingerprint
        )
    }

    private struct PosixOwner {
        var uid: UInt32
        var gid: UInt32
        var mode: UInt16
        var ownerName: String?
        var groupName: String?
    }

    private static func posixOwner(at path: String) -> PosixOwner {
        var st = stat()
        let ok = lstat(path, &st) == 0
        guard ok else {
            return PosixOwner(uid: 0, gid: 0, mode: 0o644, ownerName: nil, groupName: nil)
        }
        let uid = UInt32(st.st_uid)
        let gid = UInt32(st.st_gid)
        let mode = UInt16(st.st_mode & 0o7777)
        var ownerName: String?
        var groupName: String?
        if let pw = getpwuid(uid_t(uid)) {
            ownerName = String(cString: pw.pointee.pw_name)
        }
        if let gr = getgrgid(gid_t(gid)) {
            groupName = String(cString: gr.pointee.gr_name)
        }
        return PosixOwner(uid: uid, gid: gid, mode: mode, ownerName: ownerName, groupName: groupName)
    }

    private static func isSpecialFile(_ values: URLResourceValues) -> Bool {
        guard let type = values.fileResourceType else { return false }
        switch type {
        case .namedPipe, .socket, .blockSpecial, .characterSpecial:
            return true
        default:
            return false
        }
    }

    private static func symlinkEscapesSelection(target: String, root: URL, linkURL: URL) -> Bool {
        if target.hasPrefix("/") {
            let dest = URL(fileURLWithPath: target).standardizedFileURL.path
            let rootPath = root.standardizedFileURL.path
            return !(dest == rootPath || dest.hasPrefix(rootPath + "/"))
        }
        let resolved = linkURL.deletingLastPathComponent().appendingPathComponent(target).standardizedFileURL.path
        let rootPath = root.standardizedFileURL.path
        return !(resolved == rootPath || resolved.hasPrefix(rootPath + "/"))
    }
}
