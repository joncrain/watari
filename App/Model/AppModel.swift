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
    @Published var dlp: DLPPolicy = ManagedDefaults.dlpPolicy()
    @Published var network: NetworkConfig = .default
    @Published var jobLog = JobLog()
    @Published var statusMessage: String = "Add a folder to begin."
    @Published var progressFraction: Double = 0
    @Published var showConnectSheet = false
    @Published var libraryWarning: String?
    @Published var lastError: String?

    let bookmarkStore = BookmarkStore()
    let peerConnector = PeerConnector()
    let bonjour = BonjourBrowser()
    let transfer = TransferSession()
    let permissionApplier = PermissionApplier()

    var canPreview: Bool { !folderBookmarks.isEmpty && selectedPeerID != nil && phase != .copying }
    var canStart: Bool { phase == .previewReady }
    var canStop: Bool { phase == .copying }
    var exceptionCount: Int { preview?.permissionExceptionCount ?? 0 }

    var selectedPeer: PeerRecord? {
        peers.first { $0.id == selectedPeerID }
    }

    func addFolder() {
        guard let url = bookmarkStore.pickFolder() else { return }
        do {
            let entry = try bookmarkStore.save(url: url)
            folderBookmarks.append(entry)
            libraryWarning = Denylist().warningForSelectingLibraryRoot(url.path)
            phase = selectedPeerID == nil ? .waitingForPeer : (preview == nil ? .waitingForPeer : phase)
            if selectedPeerID == nil {
                phase = .waitingForPeer
                statusMessage = "Folder added. Connect a peer to continue."
            } else {
                statusMessage = "Folder added. Run Preview before starting."
                phase = .noFolders
                // keep folders; move to waiting if we had peer
                phase = .waitingForPeer
                statusMessage = "Run Preview to see what will copy."
            }
            if !folderBookmarks.isEmpty {
                if selectedPeerID == nil {
                    phase = .waitingForPeer
                } else {
                    // ready to preview — use a dedicated soft state
                    phase = .waitingForPeer
                    statusMessage = "Run Preview to see what will copy."
                }
            }
        } catch {
            lastError = error.localizedDescription
        }
    }

    func removeFolder(_ id: BookmarkEntry.ID) {
        folderBookmarks.removeAll { $0.id == id }
        preview = nil
        if folderBookmarks.isEmpty {
            phase = .noFolders
            statusMessage = "Add a folder to begin."
        }
    }

    func preview() {
        guard canPreview else { return }
        // Placeholder scan: build empty destinations until Mac scanner fills real metadata.
        let sources: [FileMetadata] = folderBookmarks.map {
            FileMetadata(relativePath: $0.displayName, isDirectory: true, mode: 0o755)
        }
        let receiving = permissionApplier.currentIdentity()
        let summary = PreviewDiff.build(sources: sources, policy: policy, dlp: dlp, receiving: receiving)
        preview = summary
        phase = .previewReady
        statusMessage = "Preview ready — \(summary.copy) copy, \(summary.update) update, \(summary.skip) skip."
    }

    func start() {
        guard canStart, let peer = selectedPeer else { return }
        phase = .copying
        statusMessage = "Copying to \(peer.displayName)…"
        progressFraction = 0
        Task {
            do {
                try await transfer.run(
                    folders: folderBookmarks,
                    peer: peer,
                    policy: policy,
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
}
