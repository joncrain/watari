import Foundation
import Testing
import WatariCore

@Suite("LocalFileIndex")
struct LocalFileIndexTests {
    @Test("totals and round-trip")
    func totals() throws {
        var index = LocalFileIndex()
        index.replace(
            rootPath: "/Users/ada/Documents",
            entries: [
                LocalIndexEntry(relativePath: "Documents/a.txt", size: 10, contentHash: "a", uid: 501, ownerName: "ada"),
                LocalIndexEntry(relativePath: "Documents/b.txt", size: 15, contentHash: "b", uid: 501, ownerName: "ada"),
                LocalIndexEntry(relativePath: "Documents", size: 0, uid: 501, ownerName: "ada"),
            ]
        )
        #expect(index.totalBytes(rootPath: "/Users/ada/Documents") == 25)
        #expect(index.totalBytes() == 25)

        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("watari-index-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        try index.save(to: url)
        let loaded = try LocalFileIndex.load(from: url)
        #expect(loaded.totalBytes() == 25)
        #expect(loaded.entries(rootPath: "/Users/ada/Documents").count == 3)
    }
}
