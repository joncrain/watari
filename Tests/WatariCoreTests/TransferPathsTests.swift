import Foundation
import Testing
import WatariCore

@Suite("TransferPaths")
struct TransferPathsTests {
    @Test("resolves relative path under display root")
    func resolve() {
        let root = URL(fileURLWithPath: "/Users/ada/Documents")
        let roots = ["Documents": root]
        #expect(TransferPaths.resolve("Documents", roots: roots) == root)
        #expect(
            TransferPaths.resolve("Documents/notes.txt", roots: roots)
                == root.appendingPathComponent("notes.txt")
        )
        #expect(TransferPaths.resolve("Desktop/a", roots: roots) == nil)
    }

    @Test("chunks and reassembles file bytes")
    func chunks() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("watari-chunk-\(UUID().uuidString).bin")
        defer { try? FileManager.default.removeItem(at: url) }
        let payload = Data((0..<2500).map { UInt8($0 % 251) })
        try payload.write(to: url)
        let parts = try FileChunkReader.readChunks(at: url, chunkSize: 1000)
        #expect(parts.count == 3)
        #expect(parts.reduce(Data(), +) == payload)
    }

    @Test("inventory request response round-trip")
    func inventoryFrames() throws {
        let req = InventoryRequestPayload(rootNames: ["Documents", "Desktop"])
        var encoded = try TransferCodec.encodeJSON(.inventoryRequest, req)
        let frame = try TransferCodec.decode(from: &encoded)
        #expect(frame?.type == .inventoryRequest)
        let decoded = try TransferCodec.decodeJSON(frame!, as: InventoryRequestPayload.self)
        #expect(decoded.rootNames == ["Documents", "Desktop"])

        let entries = [
            FileMetadata(relativePath: "Documents/a.txt", isDirectory: false, size: 1, uid: 501, contentFingerprint: "x"),
        ]
        var resp = try TransferCodec.encodeJSON(.inventoryResponse, InventoryResponsePayload(entries: entries))
        let rFrame = try TransferCodec.decode(from: &resp)
        let map = try TransferCodec.decodeJSON(rFrame!, as: InventoryResponsePayload.self).asDestinationMap
        #expect(map["Documents/a.txt"]?.contentFingerprint == "x")
    }

    @Test("destination inventory scan")
    func inventoryScan() throws {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("watari-inv-\(UUID().uuidString)", isDirectory: true)
        let docs = base.appendingPathComponent("Documents", isDirectory: true)
        try FileManager.default.createDirectory(at: docs, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: base) }
        try Data("peer".utf8).write(to: docs.appendingPathComponent("a.txt"))

        let entries = try DestinationInventory.scan(destinationRoot: base, rootNames: ["Documents", "Missing"])
        #expect(entries.contains { $0.relativePath == "Documents/a.txt" })
        #expect(entries.contains { $0.relativePath == "Documents/a.txt" && $0.contentFingerprint != nil })
    }

    @Test("receive index upsert")
    func receiveIndex() {
        var index = LocalFileIndex()
        ReceiveIndex.upsert(
            &index,
            destinationRootPath: "/recv",
            received: [
                FileMetadata(relativePath: "Documents/a.txt", isDirectory: false, size: 4, uid: 501, contentFingerprint: "h"),
            ]
        )
        #expect(index.totalBytes(rootPath: "/recv") == 4)
        ReceiveIndex.upsert(
            &index,
            destinationRootPath: "/recv",
            received: [
                FileMetadata(relativePath: "Documents/a.txt", isDirectory: false, size: 9, uid: 501, contentFingerprint: "h2"),
                FileMetadata(relativePath: "Documents/b.txt", isDirectory: false, size: 1, uid: 501, contentFingerprint: "b"),
            ]
        )
        #expect(index.totalBytes(rootPath: "/recv") == 10)
        #expect(index.entries(rootPath: "/recv").count == 2)
    }

    @Test("preview uses peer inventory for hash skip")
    func previewWithInventory() {
        let receiving = ReceivingIdentity(uid: 501, gid: 20, userName: "ada", groupName: "staff")
        let sources = [
            FileMetadata(relativePath: "Documents/a.txt", isDirectory: false, size: 4, uid: 502, contentFingerprint: "same"),
        ]
        let response = InventoryResponsePayload(entries: [
            FileMetadata(relativePath: "Documents/a.txt", isDirectory: false, size: 4, uid: 501, ownerName: "ada", contentFingerprint: "same"),
        ])
        let summary = PreviewDiff.build(
            sources: sources,
            destinations: response.asDestinationMap,
            receiving: receiving
        )
        #expect(summary.unchanged == 1)
        #expect(summary.items.first?.destination?.ownerName == "ada")
        #expect(summary.items.first?.source?.uid == 502)
    }

    @Test("offer catalog and pull request round-trip")
    func offerCatalogFrames() throws {
        let req = OfferCatalogRequestPayload()
        var encoded = try TransferCodec.encodeJSON(.offerCatalogRequest, req)
        let frame = try TransferCodec.decode(from: &encoded)
        #expect(frame?.type == .offerCatalogRequest)

        let catalog = OfferCatalogResponsePayload(
            displayName: "MacBook",
            roots: [OfferedRoot(name: "Documents", path: "/Users/a/Documents", totalBytes: 100, entryCount: 3)]
        )
        var resp = try TransferCodec.encodeJSON(.offerCatalogResponse, catalog)
        let rFrame = try TransferCodec.decode(from: &resp)
        let decoded = try TransferCodec.decodeJSON(rFrame!, as: OfferCatalogResponsePayload.self)
        #expect(decoded.roots.first?.name == "Documents")
        #expect(decoded.roots.first?.totalBytes == 100)

        var pull = try TransferCodec.encodeJSON(
            .pullRequest,
            PullRequestPayload(rootNames: ["Documents", "Desktop"])
        )
        let pFrame = try TransferCodec.decode(from: &pull)
        #expect(pFrame?.type == .pullRequest)
        let pullDecoded = try TransferCodec.decodeJSON(pFrame!, as: PullRequestPayload.self)
        #expect(pullDecoded.rootNames == ["Documents", "Desktop"])
    }
}
