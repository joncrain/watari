import Foundation

/// One indexed file under a selected root.
public struct LocalIndexEntry: Codable, Sendable, Hashable, Equatable {
    public var relativePath: String
    public var size: UInt64
    public var contentHash: String?
    public var uid: UInt32
    public var ownerName: String?

    public init(
        relativePath: String,
        size: UInt64,
        contentHash: String? = nil,
        uid: UInt32 = 0,
        ownerName: String? = nil
    ) {
        self.relativePath = relativePath
        self.size = size
        self.contentHash = contentHash
        self.uid = uid
        self.ownerName = ownerName
    }

    public init(from metadata: FileMetadata) {
        self.relativePath = metadata.relativePath
        self.size = metadata.isDirectory ? 0 : metadata.size
        self.contentHash = metadata.contentFingerprint
        self.uid = metadata.uid
        self.ownerName = metadata.ownerName
    }
}

/// Light on-disk index for selected roots — fast size totals without rescanning.
/// ponytail: JSON file, not SQLite; swap if entry counts make load slow.
public struct LocalFileIndex: Codable, Sendable, Equatable {
    public var roots: [String: [LocalIndexEntry]]

    public init(roots: [String: [LocalIndexEntry]] = [:]) {
        self.roots = roots
    }

    public mutating func replace(rootPath: String, entries: [LocalIndexEntry]) {
        roots[rootPath] = entries
    }

    public mutating func replace(rootPath: String, metadata: [FileMetadata]) {
        roots[rootPath] = metadata.map(LocalIndexEntry.init(from:))
    }

    public func entries(rootPath: String) -> [LocalIndexEntry] {
        roots[rootPath] ?? []
    }

    public func totalBytes(rootPath: String? = nil) -> UInt64 {
        if let rootPath {
            return entries(rootPath: rootPath).reduce(UInt64(0)) { $0 + $1.size }
        }
        return roots.values.flatMap { $0 }.reduce(UInt64(0)) { $0 + $1.size }
    }

    public static func load(from url: URL) throws -> LocalFileIndex {
        let data = try Data(contentsOf: url)
        return try JSONDecoder.watari.decode(LocalFileIndex.self, from: data)
    }

    public func save(to url: URL) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let data = try JSONEncoder.watari.encode(self)
        try data.write(to: url, options: .atomic)
    }
}
