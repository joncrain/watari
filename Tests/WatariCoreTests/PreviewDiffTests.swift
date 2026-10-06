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
            conflict: .update,
            receiving: receiving
        )
        #expect(summary.copy == 1)
        #expect(summary.update == 1)
        #expect(summary.unchanged == 1)
        #expect(summary.skip == 2) // denylist + special
        #expect(summary.permissionExceptionCount >= 1)
    }

    @Test("matching hash skips transfer")
    func hashSkip() {
        let sources = [
            FileMetadata(relativePath: "notes.txt", isDirectory: false, size: 4, uid: 502, contentFingerprint: "abc"),
        ]
        let destinations: [String: FileMetadata] = [
            "notes.txt": FileMetadata(relativePath: "notes.txt", isDirectory: false, size: 4, contentFingerprint: "abc"),
        ]
        let summary = PreviewDiff.build(
            sources: sources,
            destinations: destinations,
            receiving: receiving
        )
        #expect(summary.unchanged == 1)
        #expect(summary.copy == 0)
        #expect(summary.update == 0)
        #expect(summary.items.first?.action == .unchanged)
    }

    @Test("keep both renames on hash mismatch")
    func keepBothNaming() {
        let sources = [
            FileMetadata(relativePath: "notes.txt", isDirectory: false, size: 4, contentFingerprint: "new"),
        ]
        let destinations: [String: FileMetadata] = [
            "notes.txt": FileMetadata(relativePath: "notes.txt", isDirectory: false, size: 4, contentFingerprint: "old"),
            "notes 2.txt": FileMetadata(relativePath: "notes 2.txt", isDirectory: false, size: 1, contentFingerprint: "x"),
        ]
        let summary = PreviewDiff.build(
            sources: sources,
            destinations: destinations,
            conflict: .keepBoth,
            receiving: receiving
        )
        #expect(summary.keepBoth == 1)
        #expect(summary.items.first?.relativePath == "notes 3.txt")
        #expect(summary.items.first?.action == .keepBoth)
    }

    @Test("conflict skip leaves destination")
    func conflictSkip() {
        let sources = [
            FileMetadata(relativePath: "notes.txt", isDirectory: false, size: 4, contentFingerprint: "new"),
        ]
        let destinations: [String: FileMetadata] = [
            "notes.txt": FileMetadata(relativePath: "notes.txt", isDirectory: false, size: 4, contentFingerprint: "old"),
        ]
        let summary = PreviewDiff.build(
            sources: sources,
            destinations: destinations,
            conflict: .skip,
            receiving: receiving
        )
        #expect(summary.skip == 1)
        #expect(summary.items.first?.skipReason == .conflict)
    }

    @Test("same folder merges without conflict")
    func folderMerge() {
        let sources = [
            FileMetadata(relativePath: "Docs", isDirectory: true, uid: 502),
            FileMetadata(relativePath: "Docs/a.txt", isDirectory: false, size: 1, contentFingerprint: "a"),
        ]
        let destinations: [String: FileMetadata] = [
            "Docs": FileMetadata(relativePath: "Docs", isDirectory: true),
        ]
        let summary = PreviewDiff.build(
            sources: sources,
            destinations: destinations,
            conflict: .keepBoth,
            receiving: receiving
        )
        #expect(summary.items.first { $0.relativePath == "Docs" }?.action == .unchanged)
        #expect(summary.items.first { $0.relativePath == "Docs/a.txt" }?.action == .copy)
    }
}
