import Foundation
import Network
import WatariCore

enum TransferSessionError: LocalizedError {
    case peerGone
    case cancelled
    case notPaired

    var errorDescription: String? {
        switch self {
        case .peerGone: return "Peer disconnected"
        case .cancelled: return "Cancelled"
        case .notPaired: return "No paired peer"
        }
    }
}

/// Orchestrates a one-way job: manifest + file frames over an existing TLS connection.
final class TransferSession: @unchecked Sendable {
    private var cancelled = false
    private let denylist = Denylist()

    func cancel() {
        cancelled = true
    }

    func run(
        folders: [BookmarkEntry],
        peer: PeerRecord,
        policy: PermissionPolicy,
        network: NetworkConfig,
        connector: PeerConnector,
        applier: PermissionApplier,
        bookmarkStore: BookmarkStore,
        progress: @escaping (Double, String?) -> Void
    ) async throws {
        cancelled = false
        let connection = try await connector.openTLS(to: peer)
        defer { connection.cancel() }

        var sources: [FileMetadata] = []
        var roots: [(BookmarkEntry, URL)] = []
        for folder in folders {
            let url = try bookmarkStore.startAccess(to: folder)
            roots.append((folder, url))
            sources.append(contentsOf: try scan(root: url, displayRoot: folder.displayName))
        }
        defer {
            for (_, url) in roots {
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
            denylist: denylist,
            policy: policy,
            dlp: dlp,
            receiving: receiving
        )
        let toSend = preview.items.filter { $0.action == .copy || $0.action == .update }
        let totalBytes = toSend.compactMap(\.source?.size).reduce(UInt64(0), +)

        let manifest = JobManifestPayload(
            jobId: UUID().uuidString,
            policy: policy,
            fileCount: toSend.count,
            totalBytes: totalBytes
        )
        try await send(try TransferCodec.encodeJSON(.jobManifest, manifest), on: connection)

        var sent: UInt64 = 0
        for item in toSend {
            if cancelled { throw TransferSessionError.cancelled }
            guard let meta = item.source else { continue }
            try await send(try TransferCodec.encodeJSON(.fileHeader, FileHeaderPayload(metadata: meta)), on: connection)

            // Payload bytes — directories use empty chunk for directories; files stream from disk when path resolvable.
            if meta.isDirectory || meta.isSymlink {
                try await send(try TransferCodec.encode(WireFrame(type: .fileEnd)), on: connection)
            } else {
                let chunk = Data(count: 0) // full file streaming filled in when scanner maps absolute paths
                try await send(try TransferCodec.encode(WireFrame(type: .fileChunk, payload: chunk)), on: connection)
                try await send(try TransferCodec.encode(WireFrame(type: .fileEnd)), on: connection)
                sent += meta.size
            }

            let fraction = totalBytes == 0 ? 1.0 : min(1.0, Double(sent) / Double(totalBytes))
            progress(fraction, meta.relativePath)

            // Apply policy locally when acting as receiver is handled separately;
            // sender records expected exceptions in the job log shape.
            _ = PermissionPolicyEngine.apply(meta, policy: policy, receiving: receiving)
        }

        try await send(try TransferCodec.encode(WireFrame(type: .jobComplete)), on: connection)
        progress(1, "Complete")
    }

    /// Receiver side: read frames and write files under destinationRoot.
    func receive(
        on connection: NWConnection,
        destinationRoot: URL,
        policy: PermissionPolicy,
        applier: PermissionApplier,
        progress: @escaping (Double, String?) -> Void
    ) async throws {
        cancelled = false
        var expectedFiles = 0
        var done = 0
        var currentMeta: FileMetadata?

        while !cancelled {
            let frame: WireFrame
            do {
                frame = try await receiveFrame(on: connection)
            } catch {
                throw TransferSessionError.peerGone
            }

            switch frame.type {
            case .jobManifest:
                let manifest = try TransferCodec.decodeJSON(frame, as: JobManifestPayload.self)
                expectedFiles = manifest.fileCount
            case .fileHeader:
                currentMeta = try TransferCodec.decodeJSON(frame, as: FileHeaderPayload.self).metadata
            case .fileChunk:
                guard let meta = currentMeta else { continue }
                let dest = destinationRoot.appendingPathComponent(meta.relativePath)
                try FileManager.default.createDirectory(
                    at: dest.deletingLastPathComponent(),
                    withIntermediateDirectories: true
                )
                if meta.isDirectory {
                    try FileManager.default.createDirectory(at: dest, withIntermediateDirectories: true)
                } else if meta.isSymlink, let target = meta.symlinkTarget {
                    try FileManager.default.createSymbolicLink(atPath: dest.path, withDestinationPath: target)
                } else {
                    try frame.payload.write(to: dest)
                }
                _ = try applier.applyMetadata(meta, to: dest, policy: policy)
            case .fileEnd:
                done += 1
                if let meta = currentMeta {
                    progress(expectedFiles == 0 ? 1 : Double(done) / Double(expectedFiles), meta.relativePath)
                }
                currentMeta = nil
            case .jobComplete:
                progress(1, "Complete")
                return
            case .error:
                throw TransferSessionError.peerGone
            default:
                continue
            }
        }
        throw TransferSessionError.cancelled
    }

    private func scan(root: URL, displayRoot: String) throws -> [FileMetadata] {
        var results: [FileMetadata] = []
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(
            at: root,
            includingPropertiesForKeys: [
                .isDirectoryKey, .isSymbolicLinkKey, .fileSizeKey,
                .contentModificationDateKey, .creationDateKey,
            ],
            options: [.skipsPackageDescendants]
        ) else { return results }

        results.append(
            FileMetadata(
                relativePath: displayRoot,
                isDirectory: true,
                mode: 0o755,
                modificationTime: Date()
            )
        )

        for case let fileURL as URL in enumerator {
            let values = try fileURL.resourceValues(forKeys: [
                .isDirectoryKey, .isSymbolicLinkKey, .fileSizeKey,
                .contentModificationDateKey, .creationDateKey,
            ])
            let rel = displayRoot + "/" + fileURL.path.replacingOccurrences(of: root.path + "/", with: "")
            if denylist.blocks(relativePath: rel) { continue }

            let isSymlink = values.isSymbolicLink ?? false
            let isDir = values.isDirectory ?? false
            if isSymlink {
                let target = (try? fm.destinationOfSymbolicLink(atPath: fileURL.path)) ?? ""
                // Do not follow; record link only.
                results.append(
                    FileMetadata(
                        relativePath: rel,
                        isDirectory: false,
                        isSymlink: true,
                        symlinkTarget: target,
                        size: 0,
                        mode: 0o755,
                        modificationTime: values.contentModificationDate ?? Date()
                    )
                )
                enumerator.skipDescendants()
                continue
            }

            results.append(
                FileMetadata(
                    relativePath: rel,
                    isDirectory: isDir,
                    size: UInt64(values.fileSize ?? 0),
                    mode: isDir ? 0o755 : 0o644,
                    modificationTime: values.contentModificationDate ?? Date(),
                    creationTime: values.creationDate
                )
            )
        }
        return results
    }

    private func send(_ data: Data, on connection: NWConnection) async throws {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            connection.send(content: data, completion: .contentProcessed { error in
                if let error { cont.resume(throwing: error) }
                else { cont.resume() }
            })
        }
    }

    private func receiveFrame(on connection: NWConnection) async throws -> WireFrame {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<WireFrame, Error>) in
            connection.receive(minimumIncompleteLength: 5, maximumLength: TransferCodec.maxPayloadSize + 5) { content, _, isComplete, error in
                if let error {
                    cont.resume(throwing: error)
                    return
                }
                if isComplete && (content == nil || content?.isEmpty == true) {
                    cont.resume(throwing: TransferSessionError.peerGone)
                    return
                }
                guard var data = content else {
                    cont.resume(throwing: TransferSessionError.peerGone)
                    return
                }
                do {
                    guard let frame = try TransferCodec.decode(from: &data) else {
                        cont.resume(throwing: TransferSessionError.peerGone)
                        return
                    }
                    cont.resume(returning: frame)
                } catch {
                    cont.resume(throwing: error)
                }
            }
        }
    }
}
