import Foundation
import Testing
import WatariCore

@Suite("PreviewDiff")
struct PreviewDiffTests {
    let receiving = ReceivingIdentity(uid: 501, gid: 20, userName: "ada", groupName: "staff")

    @Test("counts copy update unchanged and skip")
    func summaryCounts() {
        let sources = [
            FileMetadata(relativePath: "a.txt", isDirectory: false, size: 1, contentFingerprint: "a"),
            FileMetadata(relativePath: "b.txt", isDirectory: false, size: 2, contentFingerprint: "b2"),
            FileMetadata(relativePath: "c.txt", isDirectory: false, size: 3, contentFingerprint: "c"),
            FileMetadata(relativePath: "Library/Keychains/login.keychain-db", isDirectory: false, size: 9),
        ]
        let destinations: [String: FileMetadata] = [
            "b.txt": FileMetadata(relativePath: "b.txt", isDirectory: false, size: 2, contentFingerprint: "b1"),
            "c.txt": FileMetadata(relativePath: "c.txt", isDirectory: false, size: 3, contentFingerprint: "c"),
        ]
        let summary = PreviewDiff.build(
            sources: sources,
            destinations: destinations,
            skipped: [("sock", .specialFile)],
            receiving: receiving
        )
        #expect(summary.copy == 1)
        #expect(summary.update == 1)
        #expect(summary.unchanged == 1)
        #expect(summary.skip == 2) // denylist + special
        #expect(summary.permissionExceptionCount >= 1)
    }
}
