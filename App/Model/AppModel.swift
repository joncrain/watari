import Foundation
import SwiftUI
import WatariCore

@MainActor
final class AppModel: ObservableObject {
    enum Phase: Equatable {
        case noFolders
        case waitingForPeer
        case previewReady
        case copying
        case finishedWithExceptions
        case peerGone
    }

    @Published var phase: Phase = .noFolders
    @Published var folderBookmarks: [BookmarkEntry] = []
    @Published var peers: [PeerRecord] = []
    @Published var selectedPeerID: PeerRecord.ID?
    @Published var preview: PreviewSummary?
    @Published var policy: PermissionPolicy = .default
    @Published var conflict: ConflictPolicy = .default
    @Published var dlp: DLPPolicy = ManagedDefaults.dlpPolicy()
    @Published var network: NetworkConfig = .default
    @Published var jobLog = JobLog()
    @Published var statusMessage: String = "Add a folder to begin."
    @Published var progressFraction: Double = 0
    @Published var showConnectSheet = false
    @Published var libraryWarning: String?
    @Published var lastError: String?
    @Published var indexedBytes: UInt64 = 0

    let bookmarkStore = BookmarkStore()
    let peerConnector = PeerConnector()
    let bonjour = BonjourBrowser()
    let transfer = TransferSession()
    let permissionApplier = PermissionApplier()

    private var fileIndex = LocalFileIndex()
    private let indexURL: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return base.appendingPathComponent("Watari", isDirectory: true)
            .appendingPathComponent("local-index.json")
    }()

    var canPreview: Bool { !folderBookmarks.isEmpty && selectedPeerID != nil && phase != .copying }
    var canStart: Bool { phase == .previewReady }
    var canStop: Bool { phase == .copying }
    var exceptionCount: Int { preview?.permissionExceptionCount ?? 0 }

    var selectedPeer: PeerRecord? {
        peers.first { $0.id == selectedPeerID }
    }

    init() {
        if let loaded = try? LocalFileIndex.load(from: indexURL) {
            fileIndex = loaded
            indexedBytes = loaded.totalBytes()
        }
    }

    func addFolder() {
        guard let url = bookmarkStore.pickFolder() else { return }
        ingestFolder(url)
    }

    func addConvenience(_ target: ConvenienceTarget) {
        guard let url = bookmarkStore.pickConvenience(target) else { return }
        ingestFolder(url)
    }

    private func ingestFolder(_ url: URL) {
        do {
            let entry = try bookmarkStore.save(url: url)
            if folderBookmarks.contains(where: { $0.path == entry.path }) {
                statusMessage = "\(entry.displayName) is already in this job."
                return
            }
            folderBookmarks.append(entry)
            libraryWarning = Denylist().warningForSelectingLibraryRoot(url.path)
            preview = nil
            if selectedPeerID == nil {
                phase = .waitingForPeer
                statusMessage = "Folder added. Connect a peer to continue."
            } else {
                phase = .waitingForPeer
                statusMessage = "Run Preview to see what will copy."
            }
        } catch {
            lastError = error.localizedDescription
        }
    }

    func removeFolder(_ id: BookmarkEntry.ID) {
        if let entry = folderBookmarks.first(where: { $0.id == id }) {
            fileIndex.roots.removeValue(forKey: entry.path)
            persistIndex()
        }
        folderBookmarks.removeAll { $0.id == id }
        preview = nil
        if folderBookmarks.isEmpty {
            phase = .noFolders
            statusMessage = "Add a folder to begin."
        }
    }

    func preview() {
        guard canPreview else { return }
        do {
            var sources: [FileMetadata] = []
            var skipped: [(path: String, reason: SkipReason)] = []
            for folder in folderBookmarks {
                let url = try bookmarkStore.startAccess(to: folder)
                defer { bookmarkStore.stopAccess(to: url) }
                let scanned = try FileScanner.scan(
                    root: url,
                    displayRoot: folder.displayName,
                    denylist: Denylist()
                )
                sources.append(contentsOf: scanned.entries)
                skipped.append(contentsOf: scanned.skipped)
                fileIndex.replace(rootPath: folder.path, metadata: scanned.entries)
            }
            persistIndex()

            // Destination inventory from peer is M2; hash-skip/keep-both still work when destinations are supplied.
            let destinations: [String: FileMetadata] = [:]
            let receiving = permissionApplier.currentIdentity()
            let summary = PreviewDiff.build(
                sources: sources,
                destinations: destinations,
                skipped: skipped,
                policy: policy,
                conflict: conflict,
                dlp: dlp,
                receiving: receiving
            )
            preview = summary
            phase = .previewReady
            statusMessage =
                "Preview ready — \(summary.copy) copy, \(summary.update) update, \(summary.unchanged) unchanged, \(summary.keepBoth) keep both, \(summary.skip) skip · \(ByteCountFormatter.string(fromByteCount: Int64(indexedBytes), countStyle: .file)) indexed"
        } catch {
            lastError = error.localizedDescription
            statusMessage = "Preview failed — \(error.localizedDescription)"
        }
    }

    func start() {
        guard canStart, let peer = selectedPeer else { return }
        phase = .copying
        statusMessage = "Copying to \(peer.displayName)…"
        progressFraction = 0
        let conflictPolicy = conflict
        Task {
            do {
                try await transfer.run(
                    folders: folderBookmarks,
                    peer: peer,
                    policy: policy,
                    conflict: conflictPolicy,
                    network: network,
                    connector: peerConnector,
                    applier: permissionApplier,
                    bookmarkStore: bookmarkStore
                ) { [weak self] fraction, message in
                    Task { @MainActor in
                        self?.progressFraction = fraction
                        if let message { self?.statusMessage = message }
                    }
                }
                await MainActor.run {
                    self.phase = (self.exceptionCount > 0) ? .finishedWithExceptions : .previewReady
                    self.statusMessage = self.exceptionCount > 0
                        ? "Finished with \(self.exceptionCount) permission note(s)."
                        : "Finished."
                    self.progressFraction = 1
                }
            } catch TransferSessionError.peerGone {
                await MainActor.run {
                    self.phase = .peerGone
                    self.statusMessage = "Peer disconnected mid-copy."
                }
            } catch {
                await MainActor.run {
                    self.lastError = error.localizedDescription
                    self.phase = .previewReady
                    self.statusMessage = "Stopped — \(error.localizedDescription)"
                }
            }
        }
    }

    func stop() {
        transfer.cancel()
        statusMessage = "Stopping…"
    }

    func applyConnection(_ profile: ConnectionProfile) {
        let peer = PeerRecord(
            displayName: profile.displayName,
            host: profile.host,
            port: profile.port,
            publicKey: profile.publicKey ?? Data()
        )
        peers.append(peer)
        selectedPeerID = peer.id
        showConnectSheet = false
        if folderBookmarks.isEmpty {
            phase = .noFolders
            statusMessage = "Peer saved. Add a folder to begin."
        } else {
            phase = .waitingForPeer
            statusMessage = "Peer connected. Run Preview."
        }
    }

    private func persistIndex() {
        indexedBytes = fileIndex.totalBytes()
        try? fileIndex.save(to: indexURL)
    }
}
