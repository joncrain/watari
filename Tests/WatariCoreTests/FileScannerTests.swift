import Foundation
import Testing
import WatariCore

@Suite("FileScanner")
struct FileScannerTests {
    @Test("captures size owner and content hash")
    func scanMetadata() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("watari-scan-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let file = root.appendingPathComponent("hello.txt")
        let payload = Data("hello watari".utf8)
        try payload.write(to: file)

        let result = try FileScanner.scan(root: root, displayRoot: "TmpRoot")
        let entry = result.entries.first { $0.relativePath == "TmpRoot/hello.txt" }
        #expect(entry != nil)
        #expect(entry?.size == UInt64(payload.count))
        #expect(entry?.contentFingerprint == ContentHash.sha256Hex(of: payload))
        // Remap default still exercised via PermissionPolicyEngine on scanned metadata.
        let receiving = ReceivingIdentity(uid: 501, gid: 20, userName: "ada", groupName: "staff")
        let applied = PermissionPolicyEngine.apply(entry!, policy: .default, receiving: receiving)
        #expect(applied.metadata.uid == 501)
        #expect(applied.metadata.ownerName == "ada")
    }

    @Test("sha256 known vector")
    func sha256Vector() {
        // SHA-256("") 
        #expect(
            ContentHash.sha256Hex(of: Data())
                == "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"
        )
    }
}
