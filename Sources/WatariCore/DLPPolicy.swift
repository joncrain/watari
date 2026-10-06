import Foundation

/// Data Loss Prevention controls for enterprise installs (MDM-configurable).
/// v1 ships the model and evaluation helpers; enforcement is wired in a later release
/// when `enabled` is true via managed preferences.
public struct DLPPolicy: Codable, Sendable, Equatable {
    public var enabled: Bool
    /// When true, UI cannot weaken DLP (Managed).
    public var locked: Bool
    /// File extension denylist (lowercase, without dot), e.g. `pem`, `p12`, `key`.
    public var blockedExtensions: [String]
    /// Glob-like path suffixes that must not leave the Mac (relative paths).
    public var blockedPathSuffixes: [String]
    /// Maximum file size in bytes; 0 = unlimited.
    public var maxFileBytes: UInt64
    /// Block files whose names match these case-insensitive substrings.
    public var blockedNameSubstrings: [String]
    /// Require destination peer to be on the allowlist (pinned peers only).
    public var requireAllowlistedPeer: Bool
    /// Block outbound jobs entirely (receive-only / freeze).
    public var blockOutbound: Bool
    /// Block inbound jobs entirely (send-only / freeze).
    public var blockInbound: Bool
    /// Optional label written into the audit log for SIEM correlation.
    public var policyLabel: String?

    public init(
        enabled: Bool = false,
        locked: Bool = false,
        blockedExtensions: [String] = [],
        blockedPathSuffixes: [String] = [],
        maxFileBytes: UInt64 = 0,
        blockedNameSubstrings: [String] = [],
        requireAllowlistedPeer: Bool = false,
        blockOutbound: Bool = false,
        blockInbound: Bool = false,
        policyLabel: String? = nil
    ) {
        self.enabled = enabled
        self.locked = locked
        self.blockedExtensions = blockedExtensions.map { $0.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: ".")) }
        self.blockedPathSuffixes = blockedPathSuffixes
        self.maxFileBytes = maxFileBytes
        self.blockedNameSubstrings = blockedNameSubstrings
        self.requireAllowlistedPeer = requireAllowlistedPeer
        self.blockOutbound = blockOutbound
        self.blockInbound = blockInbound
        self.policyLabel = policyLabel
    }

    public static let disabled = DLPPolicy()
}

public enum DLPVerdict: String, Codable, Sendable, Equatable {
    case allow
    case blockExtension
    case blockPath
    case blockName
    case blockSize
    case blockOutbound
    case blockInbound
    case blockPeerNotAllowlisted
}

public enum DLPEngine {
    public static func evaluateFile(
        relativePath: String,
        size: UInt64,
        policy: DLPPolicy
    ) -> DLPVerdict {
        guard policy.enabled else { return .allow }

        let name = relativePath.split(separator: "/").last.map(String.init) ?? relativePath
        let lowerName = name.lowercased()
        let lowerPath = relativePath.lowercased()

        if let ext = extensionOf(name), policy.blockedExtensions.contains(ext) {
            return .blockExtension
        }
        for suffix in policy.blockedPathSuffixes {
            let s = suffix.lowercased()
            if lowerPath.hasSuffix(s) || lowerPath.contains("/" + s) {
                return .blockPath
            }
        }
        for token in policy.blockedNameSubstrings {
            if lowerName.contains(token.lowercased()) {
                return .blockName
            }
        }
        if policy.maxFileBytes > 0, size > policy.maxFileBytes {
            return .blockSize
        }
        return .allow
    }

    public static func evaluateJobDirection(outbound: Bool, policy: DLPPolicy) -> DLPVerdict {
        guard policy.enabled else { return .allow }
        if outbound, policy.blockOutbound { return .blockOutbound }
        if !outbound, policy.blockInbound { return .blockInbound }
        return .allow
    }

    public static func evaluatePeer(isAllowlisted: Bool, policy: DLPPolicy) -> DLPVerdict {
        guard policy.enabled else { return .allow }
        if policy.requireAllowlistedPeer, !isAllowlisted {
            return .blockPeerNotAllowlisted
        }
        return .allow
    }

    private static func extensionOf(_ name: String) -> String? {
        guard let dot = name.lastIndex(of: "."), dot != name.startIndex else { return nil }
        return String(name[name.index(after: dot)...]).lowercased()
    }
}

public enum DLPManagedKey {
    public static let enabled = "DLPEnabled"
    public static let locked = "DLPLocked"
    public static let blockedExtensions = "DLPBlockedExtensions"
    public static let blockedPathSuffixes = "DLPBlockedPathSuffixes"
    public static let maxFileBytes = "DLPMaxFileBytes"
    public static let blockedNameSubstrings = "DLPBlockedNameSubstrings"
    public static let requireAllowlistedPeer = "DLPRequireAllowlistedPeer"
    public static let blockOutbound = "DLPBlockOutbound"
    public static let blockInbound = "DLPBlockInbound"
    public static let policyLabel = "DLPPolicyLabel"
}
