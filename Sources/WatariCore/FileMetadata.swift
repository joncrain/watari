import Foundation

/// Portable metadata captured for one filesystem entry inside a selection.
public struct FileMetadata: Codable, Sendable, Hashable, Equatable {
    public var relativePath: String
    public var isDirectory: Bool
    public var isSymlink: Bool
    public var symlinkTarget: String?
    public var size: UInt64
    public var mode: UInt16
    public var uid: UInt32
    public var gid: UInt32
    public var ownerName: String?
    public var groupName: String?
    public var modificationTime: Date
    public var creationTime: Date?
    public var finderFlags: UInt16
    public var aclText: String?
    public var extendedAttributes: [String: Data]
    public var contentFingerprint: String?

    public init(
        relativePath: String,
        isDirectory: Bool,
        isSymlink: Bool = false,
        symlinkTarget: String? = nil,
        size: UInt64 = 0,
        mode: UInt16 = 0o644,
        uid: UInt32 = 0,
        gid: UInt32 = 0,
        ownerName: String? = nil,
        groupName: String? = nil,
        modificationTime: Date = Date(timeIntervalSince1970: 0),
        creationTime: Date? = nil,
        finderFlags: UInt16 = 0,
        aclText: String? = nil,
        extendedAttributes: [String: Data] = [:],
        contentFingerprint: String? = nil
    ) {
        self.relativePath = relativePath
        self.isDirectory = isDirectory
        self.isSymlink = isSymlink
        self.symlinkTarget = symlinkTarget
        self.size = size
        self.mode = mode
        self.uid = uid
        self.gid = gid
        self.ownerName = ownerName
        self.groupName = groupName
        self.modificationTime = modificationTime
        self.creationTime = creationTime
        self.finderFlags = finderFlags
        self.aclText = aclText
        self.extendedAttributes = extendedAttributes
        self.contentFingerprint = contentFingerprint
    }
}

/// Special filesystem kinds Watari never transfers as opaque bytes.
public enum SkippedFileKind: String, Codable, Sendable {
    case socket
    case device
    case namedPipe
    case unknownSpecial
}
