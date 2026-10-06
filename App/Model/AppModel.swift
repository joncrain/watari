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
    @Published var receiveFolder: BookmarkEntry?
    @Published var peers: [PeerRecord] = []
    @Published var selectedPeerID: PeerRecord.ID?
    @Published var preview: PreviewSummary?
    @Published var selectedPreviewPath: String?
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
    @Published var peerInventoryAvailable = false

    let bookmarkStore = BookmarkStore()
    let peerConnector = PeerConnector()
    let bonjour = BonjourBrowser()
    let transfer = TransferSession()
    let permissionApplier = PermissionApplier()
    private(set) lazy var jobListener: JobListener = {
        let connector = self.peerConnector
        return JobListener(
            identityKey: { connector.publicKeyData },
            displayName: { Host.current().localizedName ?? "Watari Mac" }
        )
    }()

    private var fileIndex = LocalFileIndex()
    private var peerDestinations: [String: FileMetadata] = [:]
    private var receiveAccessURL: URL?
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

    var selectedPreviewItem: PreviewItem? {
        guard let path = selectedPreviewPath else { return nil }
        return preview?.items.first { $0.relativePath == path }
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

    func chooseReceiveFolder() {
        guard let url = bookmarkStore.pickFolder() else { return }
        do {
            receiveFolder = try bookmarkStore.save(url: url)
            refreshListener()
            statusMessage = "Receive into \(url.lastPathComponent)."
        } catch {
            lastError = error.localizedDescription
        }
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
            peerDestinations = [:]
            peerInventoryAvailable = false
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
        peerDestinations = [:]
        if folderBookmarks.isEmpty {
            phase = .noFolders
            statusMessage = "Add a folder to begin."
        }
    }

    func preview() {
        guard canPreview, let peer = selectedPeer else { return }
        statusMessage = "Scanning and asking peer for inventory…"
        let folders = folderBookmarks
        let conflictPolicy = conflict
        let permissionPolicy = policy
        let dlpPolicy = dlp
        Task {
            do {
                var sources: [FileMetadata] = []
                var skipped: [(path: String, reason: SkipReason)] = []
                for folder in folders {
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

                var destinations: [String: FileMetadata] = [:]
                var inventoryOK = false
                do {
                    let entries = try await transfer.fetchInventory(
                        rootNames: folders.map(\.displayName),
                        peer: peer,
                        connector: peerConnector
                    )
                    destinations = InventoryResponsePayload(entries: entries).asDestinationMap
                    inventoryOK = true
                } catch {
                    // Peer offline / old peer — Preview still runs with empty destinations.
                    inventoryOK = false
                }

                let receiving = permissionApplier.currentIdentity()
                let summary = PreviewDiff.build(
                    sources: sources,
                    destinations: destinations,
                    skipped: skipped,
                    policy: permissionPolicy,
                    conflict: conflictPolicy,
                    dlp: dlpPolicy,
                    receiving: receiving
                )
                await MainActor.run {
                    self.peerDestinations = destinations
                    self.peerInventoryAvailable = inventoryOK
                    self.preview = summary
                    self.selectedPreviewPath = summary.items.first?.relativePath
                    self.phase = .previewReady
                    let inv = inventoryOK ? "peer inventory" : "local only (peer inventory unavailable)"
                    self.statusMessage =
                        "Preview ready (\(inv)) — \(summary.copy) copy, \(summary.update) update, \(summary.unchanged) unchanged, \(summary.keepBoth) keep both, \(summary.skip) skip · \(ByteCountFormatter.string(fromByteCount: Int64(self.indexedBytes), countStyle: .file)) indexed"
                }
            } catch {
                await MainActor.run {
                    self.lastError = error.localizedDescription
                    self.statusMessage = "Preview failed — \(error.localizedDescription)"
                }
            }
        }
    }

    func start() {
        guard canStart, let peer = selectedPeer else { return }
        phase = .copying
        statusMessage = "Copying to \(peer.displayName)…"
        progressFraction = 0
        let conflictPolicy = conflict
        let destinations = peerDestinations
        Task {
            do {
                try await transfer.run(
                    folders: folderBookmarks,
                    peer: peer,
                    policy: policy,
                    conflict: conflictPolicy,
                    destinations: destinations,
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

    func refreshListener() {
        jobListener.stop()
        if let receiveAccessURL {
            bookmarkStore.stopAccess(to: receiveAccessURL)
            self.receiveAccessURL = nil
        }
        guard network.listenEnabled, let receive = receiveFolder else { return }
        do {
            let url = try bookmarkStore.startAccess(to: receive)
            receiveAccessURL = url
            try jobListener.start(
                port: network.listenPort,
                destinationRoot: url,
                applier: permissionApplier,
                onIndexUpdate: { [weak self] received in
                    Task { @MainActor in
                        guard let self else { return }
                        ReceiveIndex.upsert(
                            &self.fileIndex,
                            destinationRootPath: receive.path,
                            received: received
                        )
                        self.persistIndex()
                        self.statusMessage = "Received \(received.count) item(s); index updated."
                    }
                },
                onError: { [weak self] message in
                    Task { @MainActor in
                        self?.lastError = message
                    }
                }
            )
        } catch {
            lastError = error.localizedDescription
        }
    }

    private func persistIndex() {
        indexedBytes = fileIndex.totalBytes()
        try? fileIndex.save(to: indexURL)
    }
}
