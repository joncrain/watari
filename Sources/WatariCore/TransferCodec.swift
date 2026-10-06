import Foundation

/// Frame types on the Watari wire protocol (TLS payload framing).
public enum FrameType: UInt8, Codable, Sendable {
    case hello = 1
    case pairChallenge = 2
    case pairResponse = 3
    case jobManifest = 4
    case fileHeader = 5
    case fileChunk = 6
    case fileEnd = 7
    case jobComplete = 8
    case error = 9
    case ping = 10
    case pong = 11
    case inventoryRequest = 12
    case inventoryResponse = 13
    /// Destination asks source what roots it offers (names + index totals).
    case offerCatalogRequest = 14
    case offerCatalogResponse = 15
    /// Destination asks source to push the named roots to this connection.
    case pullRequest = 16
}

public struct WireFrame: Sendable, Equatable {
    public var type: FrameType
    public var payload: Data

    public init(type: FrameType, payload: Data = Data()) {
        self.type = type
        self.payload = payload
    }
}

/// Length-prefixed frames: 1 byte type + 4 byte big-endian length + payload.
public enum TransferCodec {
    public static let maxPayloadSize = 16 * 1024 * 1024

    public static func encode(_ frame: WireFrame) throws -> Data {
        guard frame.payload.count <= maxPayloadSize else {
            throw CodecError.payloadTooLarge(frame.payload.count)
        }
        var data = Data()
        data.append(frame.type.rawValue)
        var length = UInt32(frame.payload.count).bigEndian
        withUnsafeBytes(of: &length) { data.append(contentsOf: $0) }
        data.append(frame.payload)
        return data
    }

    public static func decode(from buffer: inout Data) throws -> WireFrame? {
        guard buffer.count >= 5 else { return nil }
        let typeByte = buffer[buffer.startIndex]
        guard let type = FrameType(rawValue: typeByte) else {
            throw CodecError.unknownFrameType(typeByte)
        }
        let lengthBytes = buffer.subdata(in: buffer.startIndex.advanced(by: 1)..<buffer.startIndex.advanced(by: 5))
        let length = lengthBytes.withUnsafeBytes { raw -> UInt32 in
            var value: UInt32 = 0
            Swift.withUnsafeMutableBytes(of: &value) { dest in
                dest.copyMemory(from: UnsafeRawBufferPointer(rebasing: raw.prefix(4)))
            }
            return UInt32(bigEndian: value)
        }
        guard length <= maxPayloadSize else {
            throw CodecError.payloadTooLarge(Int(length))
        }
        let total = 5 + Int(length)
        guard buffer.count >= total else { return nil }
        let payload = buffer.subdata(in: buffer.startIndex.advanced(by: 5)..<buffer.startIndex.advanced(by: total))
        buffer.removeSubrange(buffer.startIndex..<buffer.startIndex.advanced(by: total))
        return WireFrame(type: type, payload: payload)
    }

    public static func encodeJSON<T: Encodable>(_ type: FrameType, _ value: T) throws -> Data {
        let payload = try JSONEncoder.watari.encode(value)
        return try encode(WireFrame(type: type, payload: payload))
    }

    public static func decodeJSON<T: Decodable>(_ frame: WireFrame, as: T.Type) throws -> T {
        try JSONDecoder.watari.decode(T.self, from: frame.payload)
    }
}

public enum CodecError: Error, Equatable, Sendable {
    case payloadTooLarge(Int)
    case unknownFrameType(UInt8)
}

public struct HelloPayload: Codable, Sendable, Equatable {
    public var protocolVersion: Int
    public var appVersion: String
    public var displayName: String
    public var publicKey: Data

    public init(protocolVersion: Int = 1, appVersion: String, displayName: String, publicKey: Data) {
        self.protocolVersion = protocolVersion
        self.appVersion = appVersion
        self.displayName = displayName
        self.publicKey = publicKey
    }
}

public struct JobManifestPayload: Codable, Sendable, Equatable {
    public var jobId: String
    public var policy: PermissionPolicy
    public var conflict: ConflictPolicy
    public var fileCount: Int
    public var totalBytes: UInt64

    public init(
        jobId: String,
        policy: PermissionPolicy,
        conflict: ConflictPolicy = .default,
        fileCount: Int,
        totalBytes: UInt64
    ) {
        self.jobId = jobId
        self.policy = policy
        self.conflict = conflict
        self.fileCount = fileCount
        self.totalBytes = totalBytes
    }
}

public struct FileHeaderPayload: Codable, Sendable, Equatable {
    public var metadata: FileMetadata

    public init(metadata: FileMetadata) {
        self.metadata = metadata
    }
}

/// Sender asks the peer what already exists under these job root display names.
public struct InventoryRequestPayload: Codable, Sendable, Equatable {
    public var rootNames: [String]

    public init(rootNames: [String]) {
        self.rootNames = rootNames
    }
}

/// Peer replies with scanned destination metadata (hashes + owners) for Preview.
public struct InventoryResponsePayload: Codable, Sendable, Equatable {
    public var entries: [FileMetadata]

    public init(entries: [FileMetadata]) {
        self.entries = entries
    }

    public var asDestinationMap: [String: FileMetadata] {
        Dictionary(entries.map { ($0.relativePath, $0) }, uniquingKeysWith: { _, last in last })
    }
}

/// One folder the source Mac is willing to send.
public struct OfferedRoot: Codable, Sendable, Equatable, Identifiable, Hashable {
    public var name: String
    public var path: String
    public var totalBytes: UInt64
    public var entryCount: Int

    public var id: String { path.isEmpty ? name : path }

    public init(name: String, path: String, totalBytes: UInt64, entryCount: Int) {
        self.name = name
        self.path = path
        self.totalBytes = totalBytes
        self.entryCount = entryCount
    }
}

public struct OfferCatalogRequestPayload: Codable, Sendable, Equatable {
    public var protocolVersion: Int

    public init(protocolVersion: Int = 1) {
        self.protocolVersion = protocolVersion
    }
}

public struct OfferCatalogResponsePayload: Codable, Sendable, Equatable {
    public var displayName: String
    public var roots: [OfferedRoot]

    public init(displayName: String, roots: [OfferedRoot]) {
        self.displayName = displayName
        self.roots = roots
    }
}

/// Destination asks the source to push these offered root display names.
public struct PullRequestPayload: Codable, Sendable, Equatable {
    public var rootNames: [String]
    public var policy: PermissionPolicy
    public var conflict: ConflictPolicy

    public init(
        rootNames: [String],
        policy: PermissionPolicy = .default,
        conflict: ConflictPolicy = .default
    ) {
        self.rootNames = rootNames
        self.policy = policy
        self.conflict = conflict
    }
}

/// In-memory transport for Linux tests — not used on the wire in production.
public actor InMemoryTransport {
    private var aToB = Data()
    private var bToA = Data()

    public init() {}

    public func sendAtoB(_ data: Data) {
        aToB.append(data)
    }

    public func sendBtoA(_ data: Data) {
        bToA.append(data)
    }

    public func receiveB() throws -> WireFrame? {
        try TransferCodec.decode(from: &aToB)
    }

    public func receiveA() throws -> WireFrame? {
        try TransferCodec.decode(from: &bToA)
    }
}

extension JSONEncoder {
    static var watari: JSONEncoder {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        e.dataEncodingStrategy = .base64
        return e
    }
}

extension JSONDecoder {
    static var watari: JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        d.dataDecodingStrategy = .base64
        return d
    }
}
