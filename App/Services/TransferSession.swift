import Foundation
import Network
import WatariCore
import os.log

private let transferLog = Logger(subsystem: "app.watari.mac", category: "TransferSession")

enum TransferSessionError: LocalizedError {
    case peerGone
    case cancelled
    case notPaired
    case missingSourceFile(String)
    case inventoryFailed(String)

    var errorDescription: String? {
        switch self {
        case .peerGone: return "Peer disconnected"
        case .cancelled: return "Cancelled"
        case .notPaired: return "No paired peer"
        case .missingSourceFile(let path): return "Missing source file: \(path)"
        case .inventoryFailed(let detail): return "Inventory failed: \(detail)"
        }
    }
}

/// Orchestrates inventory Preview + one-way transfer over TLS.
final class TransferSession: @unchecked Sendable {
    private var cancelled = false
    private let denylist = Denylist()
    private let chunkSize = FileChunkReader.defaultChunkSize

    func cancel() {
        cancelled = true
    }

    /// Ask peer for destination metadata under the job root display names.
    func fetchInventory(
        rootNames: [String],
        peer: PeerRecord,
        connector: PeerConnector
    ) async throws -> [FileMetadata] {
        cancelled = false
        let connection = try await connector.openTLS(to: peer)
        defer { connection.cancel() }

        let frames = FrameBuffer()
        try await send(
            try TransferCodec.encodeJSON(.inventoryRequest, InventoryRequestPayload(rootNames: rootNames)),
            on: connection
        )
        let frame = try await receiveFrame(on: connection, buffer: frames)
        guard frame.type == .inventoryResponse else {
            throw TransferSessionError.inventoryFailed("Expected inventoryResponse, got \(frame.type)")
        }
        return try TransferCodec.decodeJSON(frame, as: InventoryResponsePayload.self).entries
    }

    /// Destination-primary: ask the source what folder roots it offers (from its index).
    /// Opens one TLS session (Hello + catalog). Do not call after a separate `pair()` —
    /// that left an orphaned Hello connection and raced a second socket (“Peer disconnected”).
    func fetchOfferCatalog(
        peer: PeerRecord,
        connector: PeerConnector
    ) async throws -> OfferCatalogResponsePayload {
        cancelled = false
        let connection = try await connector.openTLS(to: peer)
        defer { connection.cancel() }
        return try await fetchOfferCatalog(on: connection)
    }

    /// Catalog request on an already Hello’d connection (same socket as pairing).
    func fetchOfferCatalog(on connection: NWConnection) async throws -> OfferCatalogResponsePayload {
        let frames = FrameBuffer()
        try await send(
            try TransferCodec.encodeJSON(.offerCatalogRequest, OfferCatalogRequestPayload()),
            on: connection
        )
        let frame: WireFrame
        do {
            frame = try await receiveFrame(on: connection, buffer: frames)
        } catch {
            throw TransferSessionError.inventoryFailed(
                "Peer closed while loading folders (\(error.localizedDescription)). Confirm Listen is on and both Macs run the same Watari build."
            )
        }
        guard frame.type == .offerCatalogResponse else {
            throw TransferSessionError.inventoryFailed("Expected offerCatalogResponse, got \(frame.type)")
        }
        return try TransferCodec.decodeJSON(frame, as: OfferCatalogResponsePayload.self)
    }

    /// Destination-primary: ask the source to push selected roots into mapped destination folders.
    func pull(
        rootNames: [String],
        peer: PeerRecord,
        policy: PermissionPolicy,
        conflict: ConflictPolicy,
        destinationRoots: [String: URL],
        connector: PeerConnector,
        applier: PermissionApplier,
        onIndexUpdate: @escaping @Sendable ([FileMetadata]) -> Void,
        progress: @escaping @Sendable (Double, String?) -> Void
    ) async throws {
        cancelled = false
        let connection = try await connector.openTLS(to: peer)
        defer { connection.cancel() }

        try await send(
            try TransferCodec.encodeJSON(
                .pullRequest,
                PullRequestPayload(rootNames: rootNames, policy: policy, conflict: conflict)
            ),
            on: connection
        )
        try await receiveJob(
            firstFrame: nil,
            on: connection,
            buffer: FrameBuffer(),
            destinationRoots: destinationRoots,
            policy: policy,
            applier: applier,
            onIndexUpdate: onIndexUpdate,
            progress: progress
        )
    }

    func run(
        folders: [BookmarkEntry],
        peer: PeerRecord,
        policy: PermissionPolicy,
        conflict: ConflictPolicy = .default,
        destinations: [String: FileMetadata] = [:],
        network: NetworkConfig,
        connector: PeerConnector,
        applier: PermissionApplier,
        bookmarkStore: BookmarkStore,
        progress: @escaping @Sendable (Double, String?) -> Void
    ) async throws {
        cancelled = false
        let connection = try await connector.openTLS(to: peer)
        defer { connection.cancel() }

        var sources: [FileMetadata] = []
        var skipped: [(path: String, reason: SkipReason)] = []
        var roots: [String: URL] = [:]
        var accessed: [URL] = []
        for folder in folders {
            let access = try bookmarkStore.startAccessRefreshing(folder)
            accessed.append(access.url)
            roots[access.entry.displayName] = access.url
            let scanned = try FileScanner.scan(
                root: access.url,
                displayRoot: access.entry.displayName,
                denylist: denylist
            )
            sources.append(contentsOf: scanned.entries)
            skipped.append(contentsOf: scanned.skipped)
        }
        defer {
            for url in accessed {
                bookmarkStore.stopAccess(to: url)
            }
        }

        let receiving = applier.currentIdentity()
        let dlp = ManagedDefaults.dlpPolicy()
        if DLPEngine.evaluateJobDirection(outbound: true, policy: dlp) != .allow {
            throw TransferSessionError.cancelled
        }
        let preview = PreviewDiff.build(
            sources: sources,
            destinations: destinations,
            denylist: denylist,
            skipped: skipped,
            policy: policy,
            conflict: conflict,
            dlp: dlp,
            receiving: receiving
        )
        let toSend = TransferPaths.itemsToTransfer(from: preview)
        let totalBytes = toSend.compactMap(\.source?.size).reduce(UInt64(0), +)

        let manifest = JobManifestPayload(
            jobId: UUID().uuidString,
            policy: policy,
            conflict: conflict,
            fileCount: toSend.count,
            totalBytes: totalBytes
        )
        try await send(try TransferCodec.encodeJSON(.jobManifest, manifest), on: connection)

        var sent: UInt64 = 0
        for item in toSend {
            if cancelled { throw TransferSessionError.cancelled }
            guard let meta = item.source else { continue }
            try await send(try TransferCodec.encodeJSON(.fileHeader, FileHeaderPayload(metadata: meta)), on: connection)

            if meta.isDirectory || meta.isSymlink {
                try await send(try TransferCodec.encode(WireFrame(type: .fileEnd)), on: connection)
            } else {
                guard let fileURL = TransferPaths.resolve(meta.relativePath, roots: roots) else {
                    throw TransferSessionError.missingSourceFile(meta.relativePath)
                }
                let chunks = try FileChunkReader.readChunks(at: fileURL, chunkSize: chunkSize)
                if chunks.isEmpty {
                    try await send(try TransferCodec.encode(WireFrame(type: .fileChunk, payload: Data())), on: connection)
                } else {
                    for chunk in chunks {
                        if cancelled { throw TransferSessionError.cancelled }
                        try await send(try TransferCodec.encode(WireFrame(type: .fileChunk, payload: chunk)), on: connection)
                        sent += UInt64(chunk.count)
                        let fraction = totalBytes == 0 ? 1.0 : min(1.0, Double(sent) / Double(totalBytes))
                        progress(fraction, meta.relativePath)
                    }
                }
                try await send(try TransferCodec.encode(WireFrame(type: .fileEnd)), on: connection)
            }

            let fraction = totalBytes == 0 ? 1.0 : min(1.0, Double(sent) / Double(totalBytes))
            progress(fraction, meta.relativePath)
            _ = PermissionPolicyEngine.apply(meta, policy: policy, receiving: receiving)
        }

        try await send(try TransferCodec.encode(WireFrame(type: .jobComplete)), on: connection)
        progress(1, "Complete")
    }

    /// Serve one inbound connection: hello already exchanged by listener, or do hello here.
    /// - Parameters:
    ///   - receiveRoot: Where inbound push jobs write (destination role).
    ///   - offeredRoots: Display-name → URL this Mac can send (source role).
    ///   - offerCatalog: Snapshot of offered roots + index totals for destination-primary UI.
    ///   - offerCatalogProvider: Optional live rebuild (Dock apps) per catalog request.
    func serve(
        on connection: NWConnection,
        receiveRoot: URL?,
        offeredRoots: [String: URL],
        offerCatalog: OfferCatalogResponsePayload,
        identityKey: Data,
        displayName: String,
        applier: PermissionApplier,
        onIndexUpdate: @escaping @Sendable ([FileMetadata]) -> Void,
        progress: @escaping @Sendable (Double, String?) -> Void,
        offerCatalogProvider: (@Sendable () -> OfferCatalogResponsePayload)? = nil
    ) async throws {
        cancelled = false
        let frames = FrameBuffer()

        // Hello exchange (client speaks first).
        let helloFrame = try await receiveFrame(on: connection, buffer: frames)
        if helloFrame.type == .hello {
            let reply = HelloPayload(
                appVersion: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.1.0",
                displayName: displayName,
                publicKey: identityKey
            )
            try await send(try TransferCodec.encodeJSON(.hello, reply), on: connection)
        } else {
            try await dispatchServerFrame(
                helloFrame,
                on: connection,
                buffer: frames,
                receiveRoot: receiveRoot,
                offeredRoots: offeredRoots,
                offerCatalog: offerCatalog,
                offerCatalogProvider: offerCatalogProvider,
                applier: applier,
                onIndexUpdate: onIndexUpdate,
                progress: progress
            )
            return
        }

        while !cancelled {
            let frame: WireFrame
            do {
                frame = try await receiveFrame(on: connection, buffer: frames)
            } catch {
                throw TransferSessionError.peerGone
            }
            let finished = try await dispatchServerFrame(
                frame,
                on: connection,
                buffer: frames,
                receiveRoot: receiveRoot,
                offeredRoots: offeredRoots,
                offerCatalog: offerCatalog,
                offerCatalogProvider: offerCatalogProvider,
                applier: applier,
                onIndexUpdate: onIndexUpdate,
                progress: progress
            )
            if finished { return }
        }
    }

    /// Returns `true` when the connection should close after handling the frame.
    @discardableResult
    private func dispatchServerFrame(
        _ frame: WireFrame,
        on connection: NWConnection,
        buffer: FrameBuffer,
        receiveRoot: URL?,
        offeredRoots: [String: URL],
        offerCatalog: OfferCatalogResponsePayload,
        offerCatalogProvider: (@Sendable () -> OfferCatalogResponsePayload)?,
        applier: PermissionApplier,
        onIndexUpdate: @escaping @Sendable ([FileMetadata]) -> Void,
        progress: @escaping @Sendable (Double, String?) -> Void
    ) async throws -> Bool {
        switch frame.type {
        case .offerCatalogRequest:
            let catalog = offerCatalogProvider?() ?? offerCatalog
            transferLog.info(
                "Sending offer catalog: \(catalog.roots.count, privacy: .public) root(s), dockApps=\(catalog.dockApps.count, privacy: .public)"
            )
            try await send(
                try TransferCodec.encodeJSON(.offerCatalogResponse, catalog),
                on: connection
            )
            return false
        case .inventoryRequest:
            try await handleInventory(
                frame,
                receiveRoot: receiveRoot,
                offeredRoots: offeredRoots,
                on: connection
            )
            return false
        case .pullRequest:
            let request = try TransferCodec.decodeJSON(frame, as: PullRequestPayload.self)
            try await pushOfferedRoots(
                names: request.rootNames,
                offeredRoots: offeredRoots,
                policy: request.policy,
                conflict: request.conflict,
                on: connection,
                progress: progress
            )
            return true
        case .jobManifest:
            guard let receiveRoot else {
                throw TransferSessionError.inventoryFailed("This Mac has no receive folder configured.")
            }
            try await receiveJob(
                firstFrame: frame,
                on: connection,
                buffer: buffer,
                destinationRoots: [:],
                fallbackDestinationParent: receiveRoot,
                applier: applier,
                onIndexUpdate: onIndexUpdate,
                progress: progress
            )
            return true
        case .pairChallenge, .ping:
            return false
        case .jobComplete:
            return true
        default:
            return false
        }
    }

    private func handleInventory(
        _ frame: WireFrame,
        receiveRoot: URL?,
        offeredRoots: [String: URL],
        on connection: NWConnection
    ) async throws {
        let request = try TransferCodec.decodeJSON(frame, as: InventoryRequestPayload.self)
        let entries: [FileMetadata]
        let offeredSubset = Dictionary(
            uniqueKeysWithValues: request.rootNames.compactMap { name -> (String, URL)? in
                guard let url = offeredRoots[name] else { return nil }
                return (name, url)
            }
        )
        if !offeredSubset.isEmpty {
            // Source inventory for destination-primary Preview.
            entries = try SourceOffer.scan(roots: offeredSubset, denylist: denylist)
        } else if let receiveRoot {
            entries = try DestinationInventory.scan(
                destinationRoot: receiveRoot,
                rootNames: request.rootNames,
                denylist: denylist
            )
        } else {
            entries = []
        }
        try await send(
            try TransferCodec.encodeJSON(.inventoryResponse, InventoryResponsePayload(entries: entries)),
            on: connection
        )
    }

    private func pushOfferedRoots(
        names: [String],
        offeredRoots: [String: URL],
        policy: PermissionPolicy,
        conflict: ConflictPolicy,
        on connection: NWConnection,
        progress: @escaping @Sendable (Double, String?) -> Void
    ) async throws {
        var roots: [String: URL] = [:]
        for name in names {
            if let url = offeredRoots[name] {
                roots[name] = url
            }
        }
        guard !roots.isEmpty else {
            throw TransferSessionError.inventoryFailed("No matching offered folders for pull request.")
        }

        var sources: [FileMetadata] = []
        var skipped: [(path: String, reason: SkipReason)] = []
        for (name, url) in roots.sorted(by: { $0.key < $1.key }) {
            let scanned = try FileScanner.scan(
                root: url,
                displayRoot: name,
                denylist: denylist
            )
            sources.append(contentsOf: scanned.entries)
            skipped.append(contentsOf: scanned.skipped)
        }

        let receiving = ReceivingIdentity(uid: 0, gid: 0, userName: "receiving", groupName: "receiving")
        let dlp = DLPPolicy()
        let preview = PreviewDiff.build(
            sources: sources,
            destinations: [:],
            denylist: denylist,
            skipped: skipped,
            policy: policy,
            conflict: conflict,
            dlp: dlp,
            receiving: receiving
        )
        let toSend = TransferPaths.itemsToTransfer(from: preview)
        let totalBytes = toSend.compactMap(\.source?.size).reduce(UInt64(0), +)

        let manifest = JobManifestPayload(
            jobId: UUID().uuidString,
            policy: policy,
            conflict: conflict,
            fileCount: toSend.count,
            totalBytes: totalBytes
        )
        try await send(try TransferCodec.encodeJSON(.jobManifest, manifest), on: connection)

        var sent: UInt64 = 0
        for item in toSend {
            if cancelled { throw TransferSessionError.cancelled }
            guard let meta = item.source else { continue }
            try await send(try TransferCodec.encodeJSON(.fileHeader, FileHeaderPayload(metadata: meta)), on: connection)

            if meta.isDirectory || meta.isSymlink {
                try await send(try TransferCodec.encode(WireFrame(type: .fileEnd)), on: connection)
            } else {
                guard let fileURL = TransferPaths.resolve(meta.relativePath, roots: roots) else {
                    throw TransferSessionError.missingSourceFile(meta.relativePath)
                }
                let chunks = try FileChunkReader.readChunks(at: fileURL, chunkSize: chunkSize)
                if chunks.isEmpty {
                    try await send(try TransferCodec.encode(WireFrame(type: .fileChunk, payload: Data())), on: connection)
                } else {
                    for chunk in chunks {
                        if cancelled { throw TransferSessionError.cancelled }
                        try await send(try TransferCodec.encode(WireFrame(type: .fileChunk, payload: chunk)), on: connection)
                        sent += UInt64(chunk.count)
                        let fraction = totalBytes == 0 ? 1.0 : min(1.0, Double(sent) / Double(totalBytes))
                        progress(fraction, meta.relativePath)
                    }
                }
                try await send(try TransferCodec.encode(WireFrame(type: .fileEnd)), on: connection)
            }
            let fraction = totalBytes == 0 ? 1.0 : min(1.0, Double(sent) / Double(totalBytes))
            progress(fraction, meta.relativePath)
        }

        try await send(try TransferCodec.encode(WireFrame(type: .jobComplete)), on: connection)
        progress(1, "Complete")
    }

    /// Receiver side: read frames and write files under a single parent (legacy push).
    func receive(
        on connection: NWConnection,
        destinationRoot: URL,
        policy: PermissionPolicy,
        conflict: ConflictPolicy = .default,
        applier: PermissionApplier,
        onIndexUpdate: (@Sendable ([FileMetadata]) -> Void)? = nil,
        progress: @escaping @Sendable (Double, String?) -> Void
    ) async throws {
        _ = conflict
        try await receiveJob(
            firstFrame: nil,
            on: connection,
            buffer: FrameBuffer(),
            destinationRoots: [:],
            fallbackDestinationParent: destinationRoot,
            policy: policy,
            applier: applier,
            onIndexUpdate: onIndexUpdate ?? { _ in },
            progress: progress
        )
    }

    private func receiveJob(
        firstFrame: WireFrame?,
        on connection: NWConnection,
        buffer: FrameBuffer,
        destinationRoots: [String: URL],
        fallbackDestinationParent: URL? = nil,
        policy: PermissionPolicy = .default,
        applier: PermissionApplier,
        onIndexUpdate: @escaping @Sendable ([FileMetadata]) -> Void,
        progress: @escaping @Sendable (Double, String?) -> Void
    ) async throws {
        cancelled = false
        var expectedFiles = 0
        var done = 0
        var currentMeta: FileMetadata?
        var fileHandle: FileHandle?
        var activePolicy = policy
        var received: [FileMetadata] = []

        func closeHandle() {
            try? fileHandle?.close()
            fileHandle = nil
        }

        func destinationURL(for relativePath: String) throws -> URL {
            if let resolved = TransferPaths.resolve(relativePath, roots: destinationRoots) {
                return resolved
            }
            if let parent = fallbackDestinationParent {
                return parent.appendingPathComponent(relativePath)
            }
            throw TransferSessionError.missingSourceFile(relativePath)
        }

        func process(_ frame: WireFrame) async throws -> Bool {
            switch frame.type {
            case .jobManifest:
                let manifest = try TransferCodec.decodeJSON(frame, as: JobManifestPayload.self)
                expectedFiles = manifest.fileCount
                activePolicy = manifest.policy
                return false
            case .fileHeader:
                closeHandle()
                let meta = try TransferCodec.decodeJSON(frame, as: FileHeaderPayload.self).metadata
                currentMeta = meta
                let dest = try destinationURL(for: meta.relativePath)
                try FileManager.default.createDirectory(
                    at: dest.deletingLastPathComponent(),
                    withIntermediateDirectories: true
                )
                if meta.isDirectory {
                    try FileManager.default.createDirectory(at: dest, withIntermediateDirectories: true)
                } else if meta.isSymlink, let target = meta.symlinkTarget {
                    if FileManager.default.fileExists(atPath: dest.path) {
                        try FileManager.default.removeItem(at: dest)
                    }
                    try FileManager.default.createSymbolicLink(atPath: dest.path, withDestinationPath: target)
                } else {
                    if FileManager.default.fileExists(atPath: dest.path) {
                        try FileManager.default.removeItem(at: dest)
                    }
                    FileManager.default.createFile(atPath: dest.path, contents: nil)
                    fileHandle = try FileHandle(forWritingTo: dest)
                }
                return false
            case .fileChunk:
                guard let meta = currentMeta, !meta.isDirectory, !meta.isSymlink else { return false }
                if let fileHandle {
                    try fileHandle.write(contentsOf: frame.payload)
                }
                return false
            case .fileEnd:
                closeHandle()
                if let meta = currentMeta {
                    let dest = try destinationURL(for: meta.relativePath)
                    _ = try applier.applyMetadata(meta, to: dest, policy: activePolicy)
                    let applied = PermissionPolicyEngine.apply(
                        meta,
                        policy: activePolicy,
                        receiving: applier.currentIdentity()
                    ).metadata
                    received.append(applied)
                    done += 1
                    progress(expectedFiles == 0 ? 1 : Double(done) / Double(expectedFiles), meta.relativePath)
                }
                currentMeta = nil
                return false
            case .jobComplete:
                onIndexUpdate(received)
                progress(1, "Complete")
                return true
            case .error:
                throw TransferSessionError.peerGone
            default:
                return false
            }
        }

        if let firstFrame {
            if try await process(firstFrame) { return }
        }

        while !cancelled {
            let frame: WireFrame
            do {
                frame = try await receiveFrame(on: connection, buffer: buffer)
            } catch {
                throw TransferSessionError.peerGone
            }
            if try await process(frame) { return }
        }
        throw TransferSessionError.cancelled
    }

    private func send(_ data: Data, on connection: NWConnection) async throws {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            connection.send(content: data, completion: .contentProcessed { error in
                if let error { cont.resume(throwing: error) }
                else { cont.resume() }
            })
        }
    }

    private func receiveFrame(on connection: NWConnection, buffer: FrameBuffer) async throws -> WireFrame {
        if let ready = try buffer.nextFrame() {
            return ready
        }
        while true {
            let chunk: Data = try await withCheckedThrowingContinuation { cont in
                connection.receive(
                    minimumIncompleteLength: 1,
                    maximumLength: TransferCodec.maxPayloadSize + 5
                ) { content, _, isComplete, error in
                    if let error {
                        cont.resume(throwing: error)
                        return
                    }
                    if isComplete && (content == nil || content?.isEmpty == true) {
                        cont.resume(throwing: TransferSessionError.peerGone)
                        return
                    }
                    guard let data = content, !data.isEmpty else {
                        cont.resume(throwing: TransferSessionError.peerGone)
                        return
                    }
                    cont.resume(returning: data)
                }
            }
            buffer.append(chunk)
            if let frame = try buffer.nextFrame() {
                return frame
            }
        }
    }
}
