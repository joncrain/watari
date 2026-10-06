import Foundation

/// Resolve job-relative paths against selected root display names.
public enum TransferPaths {
    /// `roots` maps display root name → absolute root URL.
    public static func resolve(_ relativePath: String, roots: [String: URL]) -> URL? {
        for (name, root) in roots {
            if relativePath == name { return root }
            let prefix = name + "/"
            if relativePath.hasPrefix(prefix) {
                let rest = String(relativePath.dropFirst(prefix.count))
                return root.appendingPathComponent(rest)
            }
        }
        return nil
    }

    public static func itemsToTransfer(from preview: PreviewSummary) -> [PreviewItem] {
        preview.items.filter {
            $0.action == .copy || $0.action == .update || $0.action == .keepBoth
        }
    }
}

/// Chunk a regular file for wire `fileChunk` frames.
public enum FileChunkReader {
    public static let defaultChunkSize = 1024 * 1024

    public static func readChunks(
        at url: URL,
        chunkSize: Int = defaultChunkSize
    ) throws -> [Data] {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var chunks: [Data] = []
        while true {
            let chunk = handle.readData(ofLength: chunkSize)
            if chunk.isEmpty { break }
            chunks.append(chunk)
        }
        return chunks
    }
}

/// Scan destination roots for inventory responses.
public enum DestinationInventory {
    public static func scan(
        destinationRoot: URL,
        rootNames: [String],
        denylist: Denylist = Denylist(),
        hashContents: Bool = true
    ) throws -> [FileMetadata] {
        var entries: [FileMetadata] = []
        let fm = FileManager.default
        for name in rootNames {
            let url = destinationRoot.appendingPathComponent(name)
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: url.path, isDirectory: &isDir), isDir.boolValue else {
                continue
            }
            let scanned = try FileScanner.scan(
                root: url,
                displayRoot: name,
                denylist: denylist,
                hashContents: hashContents
            )
            entries.append(contentsOf: scanned.entries)
        }
        return entries
    }
}

/// Merge received files into the local index for the destination root.
public enum ReceiveIndex {
    public static func upsert(
        _ index: inout LocalFileIndex,
        destinationRootPath: String,
        received: [FileMetadata]
    ) {
        var byPath = Dictionary(
            uniqueKeysWithValues: index.entries(rootPath: destinationRootPath).map {
                ($0.relativePath, $0)
            }
        )
        for meta in received {
            byPath[meta.relativePath] = LocalIndexEntry(from: meta)
        }
        index.replace(rootPath: destinationRootPath, entries: Array(byPath.values))
    }
}
