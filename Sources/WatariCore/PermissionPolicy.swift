import Foundation

/// Explicit metadata policy applied on the receiving Mac.
public struct PermissionPolicy: Codable, Sendable, Equatable {
    /// Map ownership to the receiving Mac's user (default). When false, attempt to keep numeric uid/gid.
    public var remapOwnerToReceivingUser: Bool
    /// Keep POSIX mode bits.
    public var keepMode: Bool
    /// Keep ACLs when they still resolve after owner remap; otherwise drop and list.
    public var keepACLs: Bool
    /// Strip `com.apple.quarantine` by default.
    public var stripQuarantine: Bool
    /// Keep other extended attributes.
    public var keepExtendedAttributes: Bool
    /// Keep Finder flags.
    public var keepFinderFlags: Bool

    public init(
        remapOwnerToReceivingUser: Bool = true,
        keepMode: Bool = true,
        keepACLs: Bool = true,
        stripQuarantine: Bool = true,
        keepExtendedAttributes: Bool = true,
        keepFinderFlags: Bool = true
    ) {
        self.remapOwnerToReceivingUser = remapOwnerToReceivingUser
        self.keepMode = keepMode
        self.keepACLs = keepACLs
        self.stripQuarantine = stripQuarantine
        self.keepExtendedAttributes = keepExtendedAttributes
        self.keepFinderFlags = keepFinderFlags
    }

    public static let `default` = PermissionPolicy()
}

public struct ReceivingIdentity: Sendable, Equatable {
    public var uid: UInt32
    public var gid: UInt32
    public var userName: String
    public var groupName: String
    /// User names that still exist on the receiving Mac (for ACL keep/drop).
    public var knownUserNames: Set<String>

    public init(uid: UInt32, gid: UInt32, userName: String, groupName: String, knownUserNames: Set<String> = []) {
        self.uid = uid
        self.gid = gid
        self.userName = userName
        self.groupName = groupName
        var known = knownUserNames
        known.insert(userName)
        self.knownUserNames = known
    }
}

public enum PermissionExceptionCode: String, Codable, Sendable, Equatable {
    case aclDropped
    case quarantineStripped
    case ownerRemapped
    case ownerKeepRequiresAdmin
    case xattrDropped
}

public struct PermissionException: Codable, Sendable, Equatable {
    public var relativePath: String
    public var code: PermissionExceptionCode
    public var detail: String

    public init(relativePath: String, code: PermissionExceptionCode, detail: String) {
        self.relativePath = relativePath
        self.code = code
        self.detail = detail
    }
}

public struct AppliedMetadata: Sendable, Equatable {
    public var metadata: FileMetadata
    public var exceptions: [PermissionException]
}

public enum PermissionPolicyEngine {
    /// Apply policy to inbound metadata, producing the metadata to write plus exception notes.
    public static func apply(
        _ source: FileMetadata,
        policy: PermissionPolicy,
        receiving: ReceivingIdentity
    ) -> AppliedMetadata {
        var result = source
        var exceptions: [PermissionException] = []

        if policy.remapOwnerToReceivingUser {
            if source.uid != receiving.uid || source.gid != receiving.gid {
                exceptions.append(
                    PermissionException(
                        relativePath: source.relativePath,
                        code: .ownerRemapped,
                        detail: "Owner set to \(receiving.userName) (\(receiving.uid)) / \(receiving.groupName) (\(receiving.gid))"
                    )
                )
            }
            result.uid = receiving.uid
            result.gid = receiving.gid
            result.ownerName = receiving.userName
            result.groupName = receiving.groupName
        } else {
            exceptions.append(
                PermissionException(
                    relativePath: source.relativePath,
                    code: .ownerKeepRequiresAdmin,
                    detail: "Keeping numeric uid/gid may require administrator rights on the receiving Mac"
                )
            )
        }

        if !policy.keepMode {
            result.mode = source.isDirectory ? 0o755 : 0o644
        }

        if !policy.keepFinderFlags {
            result.finderFlags = 0
        }

        var xattrs = source.extendedAttributes
        if policy.stripQuarantine, xattrs["com.apple.quarantine"] != nil {
            xattrs.removeValue(forKey: "com.apple.quarantine")
            exceptions.append(
                PermissionException(
                    relativePath: source.relativePath,
                    code: .quarantineStripped,
                    detail: "Removed com.apple.quarantine"
                )
            )
        }
        if !policy.keepExtendedAttributes {
            if !xattrs.isEmpty {
                exceptions.append(
                    PermissionException(
                        relativePath: source.relativePath,
                        code: .xattrDropped,
                        detail: "Dropped \(xattrs.count) extended attribute(s)"
                    )
                )
            }
            xattrs = [:]
        }
        result.extendedAttributes = xattrs

        if let acl = source.aclText, policy.keepACLs {
            if aclMentionsUnknownUsers(acl, known: receiving.knownUserNames) {
                result.aclText = nil
                exceptions.append(
                    PermissionException(
                        relativePath: source.relativePath,
                        code: .aclDropped,
                        detail: "ACL dropped because it referenced users unknown on the receiving Mac"
                    )
                )
            }
        } else if source.aclText != nil, !policy.keepACLs {
            result.aclText = nil
            exceptions.append(
                PermissionException(
                    relativePath: source.relativePath,
                    code: .aclDropped,
                    detail: "ACL dropped by policy"
                )
            )
        }

        return AppliedMetadata(metadata: result, exceptions: exceptions)
    }

    /// Naive ACL username scan: tokens after `user:` in a textual ACL dump.
    static func aclMentionsUnknownUsers(_ aclText: String, known: Set<String>) -> Bool {
        let pattern = #"user:([A-Za-z0-9._-]+)"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return false }
        let range = NSRange(aclText.startIndex..<aclText.endIndex, in: aclText)
        var unknown = false
        regex.enumerateMatches(in: aclText, options: [], range: range) { match, _, _ in
            guard let match, match.numberOfRanges > 1,
                  let r = Range(match.range(at: 1), in: aclText) else { return }
            let name = String(aclText[r])
            if !known.contains(name) {
                unknown = true
            }
        }
        return unknown
    }
}
