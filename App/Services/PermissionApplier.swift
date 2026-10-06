import Foundation
import WatariCore

#if canImport(Darwin)
import Darwin
#endif

/// Applies `PermissionPolicy` when writing files on the receiving Mac.
final class PermissionApplier: Sendable {
    func currentIdentity() -> ReceivingIdentity {
        #if canImport(Darwin)
        let uid = getuid()
        let gid = getgid()
        let user = ProcessInfo.processInfo.userName
        // Primary group name best-effort
        var groupName = "staff"
        if let gr = getgrgid(gid) {
            groupName = String(cString: gr.pointee.gr_name)
        }
        return ReceivingIdentity(
            uid: UInt32(uid),
            gid: UInt32(gid),
            userName: user,
            groupName: groupName,
            knownUserNames: [user, "root"]
        )
        #else
        return ReceivingIdentity(uid: 501, gid: 20, userName: "user", groupName: "staff")
        #endif
    }

    func applyMetadata(
        _ source: FileMetadata,
        to url: URL,
        policy: PermissionPolicy
    ) throws -> [PermissionException] {
        let receiving = currentIdentity()
        let applied = PermissionPolicyEngine.apply(source, policy: policy, receiving: receiving)
        let meta = applied.metadata

        if policy.keepMode {
            try FileManager.default.setAttributes(
                [.posixPermissions: NSNumber(value: meta.mode)],
                ofItemAtPath: url.path
            )
        }

        if !policy.remapOwnerToReceivingUser {
            // Best-effort chown; may fail without privileges.
            #if canImport(Darwin)
            let result = chown(url.path, meta.uid, meta.gid)
            if result != 0 {
                // Leave exception already recorded by engine.
            }
            #endif
        }

        // Extended attributes
        #if canImport(Darwin)
        for (name, value) in meta.extendedAttributes {
            _ = value.withUnsafeBytes { raw in
                setxattr(url.path, name, raw.baseAddress, value.count, 0, 0)
            }
        }
        if policy.stripQuarantine {
            removexattr(url.path, "com.apple.quarantine", 0)
        }
        #endif

        return applied.exceptions
    }
}
