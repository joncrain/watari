import Foundation
import Testing
import WatariCore

@Suite("PermissionPolicy")
struct PermissionPolicyTests {
    let receiving = ReceivingIdentity(
        uid: 501,
        gid: 20,
        userName: "ada",
        groupName: "staff",
        knownUserNames: ["ada", "root"]
    )

    @Test("remaps owner by default")
    func remapOwner() {
        let source = FileMetadata(
            relativePath: "Documents/a.txt",
            isDirectory: false,
            size: 10,
            mode: 0o644,
            uid: 502,
            gid: 20,
            ownerName: "other",
            groupName: "staff"
        )
        let applied = PermissionPolicyEngine.apply(source, policy: .default, receiving: receiving)
        #expect(applied.metadata.uid == 501)
        #expect(applied.metadata.ownerName == "ada")
        #expect(applied.exceptions.contains { $0.code == .ownerRemapped })
    }

    @Test("strips quarantine by default")
    func stripQuarantine() {
        var source = FileMetadata(relativePath: "Downloads/app.dmg", isDirectory: false, size: 100)
        source.extendedAttributes = ["com.apple.quarantine": Data("q".utf8)]
        let applied = PermissionPolicyEngine.apply(source, policy: .default, receiving: receiving)
        #expect(applied.metadata.extendedAttributes["com.apple.quarantine"] == nil)
        #expect(applied.exceptions.contains { $0.code == .quarantineStripped })
    }

    @Test("drops ACL naming unknown users")
    func dropUnknownACL() {
        var source = FileMetadata(relativePath: "Documents/secret.txt", isDirectory: false, size: 1)
        source.aclText = "user:ghost allow read\nuser:ada allow write"
        let applied = PermissionPolicyEngine.apply(source, policy: .default, receiving: receiving)
        #expect(applied.metadata.aclText == nil)
        #expect(applied.exceptions.contains { $0.code == .aclDropped })
    }

    @Test("keeps ACL when all users known")
    func keepKnownACL() {
        var source = FileMetadata(relativePath: "Documents/ok.txt", isDirectory: false, size: 1)
        source.aclText = "user:ada allow read"
        let applied = PermissionPolicyEngine.apply(source, policy: .default, receiving: receiving)
        #expect(applied.metadata.aclText == "user:ada allow read")
    }

    @Test("keep numeric owner notes admin requirement")
    func keepNumeric() {
        let policy = PermissionPolicy(remapOwnerToReceivingUser: false)
        let source = FileMetadata(relativePath: "a", isDirectory: false, uid: 502, gid: 20)
        let applied = PermissionPolicyEngine.apply(source, policy: policy, receiving: receiving)
        #expect(applied.exceptions.contains { $0.code == .ownerKeepRequiresAdmin })
        #expect(applied.metadata.uid == 502)
    }
}
