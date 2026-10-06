import Foundation

public enum DiscoveryMode: String, Codable, Sendable, CaseIterable {
    /// No discovery UI; connect by host only.
    case off
    /// Bonjour Nearby allowed (same link-local segment).
    case nearby
    /// Explicit host/port only (enterprise default).
    case explicit
}

public enum BindMode: String, Codable, Sendable, CaseIterable {
    case localhost
    case lan
    case address
}

public struct NetworkConfig: Codable, Sendable, Equatable {
    public var listenEnabled: Bool
    public var listenPort: Int
    public var bindMode: BindMode
    /// Used when `bindMode == .address`.
    public var bindAddress: String?
    public var discoveryMode: DiscoveryMode
    public var bandwidthLimitBytesPerSecond: UInt64
    public var idleTimeoutSeconds: Int
    public var maxConcurrentTransfers: Int

    public init(
        listenEnabled: Bool = true,
        listenPort: Int = 59234,
        bindMode: BindMode = .lan,
        bindAddress: String? = nil,
        discoveryMode: DiscoveryMode = .nearby,
        bandwidthLimitBytesPerSecond: UInt64 = 0,
        idleTimeoutSeconds: Int = 120,
        maxConcurrentTransfers: Int = 4
    ) {
        self.listenEnabled = listenEnabled
        self.listenPort = listenPort
        self.bindMode = bindMode
        self.bindAddress = bindAddress
        self.discoveryMode = discoveryMode
        self.bandwidthLimitBytesPerSecond = bandwidthLimitBytesPerSecond
        self.idleTimeoutSeconds = idleTimeoutSeconds
        self.maxConcurrentTransfers = maxConcurrentTransfers
    }

    public static let `default` = NetworkConfig()
    public static let managedDefault = NetworkConfig(discoveryMode: .explicit)
}

public struct PeerRecord: Codable, Sendable, Equatable, Identifiable {
    public var id: String
    public var displayName: String
    public var host: String?
    public var port: Int?
    public var publicKey: Data
    public var pairedAt: Date

    public init(
        id: String = UUID().uuidString,
        displayName: String,
        host: String? = nil,
        port: Int? = nil,
        publicKey: Data,
        pairedAt: Date = Date()
    ) {
        self.id = id
        self.displayName = displayName
        self.host = host
        self.port = port
        self.publicKey = publicKey
        self.pairedAt = pairedAt
    }
}

public struct ConnectionProfile: Codable, Sendable, Equatable {
    public var version: Int
    public var displayName: String
    public var host: String
    public var port: Int
    public var publicKey: Data?
    public var discovery: DiscoveryMode

    public init(
        version: Int = 1,
        displayName: String,
        host: String,
        port: Int,
        publicKey: Data? = nil,
        discovery: DiscoveryMode = .explicit
    ) {
        self.version = version
        self.displayName = displayName
        self.host = host
        self.port = port
        self.publicKey = publicKey
        self.discovery = discovery
    }

    public func exportJSON() throws -> Data {
        try JSONEncoder.watari.encode(self)
    }

    public static func importJSON(_ data: Data) throws -> ConnectionProfile {
        try JSONDecoder.watari.decode(ConnectionProfile.self, from: data)
    }
}

/// Preference keys documented in docs/enterprise.md (portable names).
public enum ManagedPreferenceKey {
    public static let domain = "app.watari.mac"
    public static let managedMode = "ManagedMode"
    public static let listenEnabled = "ListenEnabled"
    public static let listenPort = "ListenPort"
    public static let bindAddress = "BindAddress"
    public static let discoveryMode = "DiscoveryMode"
    public static let bandwidthLimit = "BandwidthLimitBytesPerSecond"
    public static let idleTimeout = "IdleTimeoutSeconds"
    public static let maxConcurrent = "MaxConcurrentTransfers"
    public static let lockPermissionPolicy = "LockPermissionPolicy"
    public static let stripQuarantine = "StripQuarantine"
    public static let keepNumericOwner = "KeepNumericOwner"
    public static let peerAllowlist = "PeerAllowlist"
    public static let denyBonjour = "DenyBonjour"
    // DLP (future enforcement; keys reserved — see docs/enterprise.md)
    public static let dlpEnabled = DLPManagedKey.enabled
    public static let dlpLocked = DLPManagedKey.locked
    public static let dlpBlockedExtensions = DLPManagedKey.blockedExtensions
    public static let dlpBlockedPathSuffixes = DLPManagedKey.blockedPathSuffixes
    public static let dlpMaxFileBytes = DLPManagedKey.maxFileBytes
    public static let dlpBlockedNameSubstrings = DLPManagedKey.blockedNameSubstrings
    public static let dlpRequireAllowlistedPeer = DLPManagedKey.requireAllowlistedPeer
    public static let dlpBlockOutbound = DLPManagedKey.blockOutbound
    public static let dlpBlockInbound = DLPManagedKey.blockInbound
    public static let dlpPolicyLabel = DLPManagedKey.policyLabel
}
