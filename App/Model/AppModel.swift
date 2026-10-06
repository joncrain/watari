import AppKit
import Foundation
import SwiftUI
import UniformTypeIdentifiers
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
    @Published var previewSummary: PreviewSummary?
    @Published var selectedPreviewPath: String?
    @Published var policy: PermissionPolicy = .default
    @Published var conflict: ConflictPolicy = .default
    @Published var dlp: DLPPolicy = ManagedDefaults.dlpPolicy()
    @Published var network: NetworkConfig = .default
    @Published var jobLog = JobLog()
    @Published var statusMessage: String = "Select folders from Home to begin."
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
    var exceptionCount: Int { previewSummary?.permissionExceptionCount ?? 0 }

    var selectedPeer: PeerRecord? {
        peers.first { $0.id == selectedPeerID }
    }

    var selectedPreviewItem: PreviewItem? {
        guard let path = selectedPreviewPath else { return nil }
        return previewSummary?.items.first { $0.relativePath == path }
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

    func isFolderSelected(path: String) -> Bool {
        folderBookmarks.contains { $0.path == path }
    }

    /// Toggle a home-folder (or other) path into the job. Selecting prompts for sandbox access.
    func setFolderSelected(_ selected: Bool, url: URL) {
        if selected {
            if isFolderSelected(path: url.path) { return }
            guard let picked = bookmarkStore.pickFolder(
                startingAt: url,
                message: "Allow Watari to read “\(url.lastPathComponent)” for this transfer."
            ) else { return }
            ingestFolder(picked)
        } else if let entry = folderBookmarks.first(where: { $0.path == url.path }) {
            removeFolder(entry.id)
        }
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
            previewSummary = nil
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
        previewSummary = nil
        peerDestinations = [:]
        if folderBookmarks.isEmpty {
            phase = .noFolders
            statusMessage = "Select folders from Home to begin."
        }
    }

    func reauthorizeFolder(_ id: BookmarkEntry.ID) {
        guard let index = folderBookmarks.firstIndex(where: { $0.id == id }) else { return }
        do {
            let updated = try bookmarkStore.reauthorize(entry: folderBookmarks[index])
            folderBookmarks[index] = updated
            statusMessage = "Re-authorized \(updated.displayName)."
            previewSummary = nil
            phase = selectedPeerID == nil ? .waitingForPeer : .waitingForPeer
        } catch {
            lastError = error.localizedDescription
        }
    }

    func exportExceptionLog() {
        let peerId = selectedPeer?.id ?? "none"
        let log: JobLog
        if let previewSummary {
            log = JobLog.fromPreview(previewSummary, jobId: UUID().uuidString, peerId: peerId)
        } else {
            log = jobLog
        }
        guard !log.events.isEmpty else {
            lastError = "Nothing to export yet — run Preview first."
            return
        }
        do {
            let data = try log.jsonLinesData()
            let panel = NSSavePanel()
            panel.allowedContentTypes = [.json]
            panel.nameFieldStringValue = "watari-exceptions.jsonl"
            panel.message = "Export Preview actions and permission exceptions (JSON Lines)."
            guard panel.runModal() == .OK, let url = panel.url else { return }
            try data.write(to: url, options: .atomic)
            statusMessage = "Exported \(log.exceptionEvents.count) exception(s), \(log.events.count) event(s)."
            jobLog = log
        } catch {
            lastError = error.localizedDescription
        }
    }

    @discardableResult
    private func refreshFolderBookmarks() throws -> Bool {
        var any = false
        for i in folderBookmarks.indices {
            let result = try bookmarkStore.refreshIfStale(folderBookmarks[i])
            if result.didRefresh {
                folderBookmarks[i] = result.entry
                any = true
            }
        }
        if let receive = receiveFolder {
            let result = try bookmarkStore.refreshIfStale(receive)
            if result.didRefresh {
                receiveFolder = result.entry
                any = true
            }
        }
        return any
    }

    func preview() {
        guard canPreview, let peer = selectedPeer else { return }
        statusMessage = "Scanning and asking peer for inventory…"
        let conflictPolicy = conflict
        let permissionPolicy = policy
        let dlpPolicy = dlp
        Task {
            do {
                let refreshed = try await MainActor.run { () -> Bool in
                    try self.refreshFolderBookmarks()
                }
                let folders = await MainActor.run { self.folderBookmarks }
                var sources: [FileMetadata] = []
                var skipped: [(path: String, reason: SkipReason)] = []
                for folder in folders {
                    let access = try bookmarkStore.startAccessRefreshing(folder)
                    defer { bookmarkStore.stopAccess(to: access.url) }
                    if access.didRefresh {
                        await MainActor.run {
                            if let idx = self.folderBookmarks.firstIndex(where: { $0.id == access.entry.id }) {
                                self.folderBookmarks[idx] = access.entry
                            }
                        }
                    }
                    let scanned = try FileScanner.scan(
                        root: access.url,
                        displayRoot: access.entry.displayName,
                        denylist: Denylist()
                    )
                    sources.append(contentsOf: scanned.entries)
                    skipped.append(contentsOf: scanned.skipped)
                    fileIndex.replace(rootPath: access.entry.path, metadata: scanned.entries)
                }
                await MainActor.run { self.persistIndex() }

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
                let log = JobLog.fromPreview(
                    summary,
                    jobId: UUID().uuidString,
                    peerId: peer.id
                )
                await MainActor.run {
                    self.peerDestinations = destinations
                    self.peerInventoryAvailable = inventoryOK
                    self.previewSummary = summary
                    self.jobLog = log
                    self.selectedPreviewPath = summary.items.first?.relativePath
                    self.phase = .previewReady
                    let inv = inventoryOK ? "peer inventory" : "local only (peer inventory unavailable)"
                    let refreshNote = refreshed ? " · refreshed folder access" : ""
                    self.statusMessage =
                        "Preview ready (\(inv)) — \(summary.copy) copy, \(summary.update) update, \(summary.unchanged) unchanged, \(summary.keepBoth) keep both, \(summary.skip) skip · \(ByteCountFormatter.string(fromByteCount: Int64(self.indexedBytes), countStyle: .file)) indexed\(refreshNote)"
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
        do {
            _ = try refreshFolderBookmarks()
        } catch {
            lastError = error.localizedDescription
            return
        }
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
                ) { @Sendable [weak self] fraction, message in
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
            statusMessage = "Peer saved. Select folders from Home to begin."
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
            let access = try bookmarkStore.startAccessRefreshing(receive)
            if access.didRefresh {
                receiveFolder = access.entry
            }
            receiveAccessURL = access.url
            let receivePath = access.entry.path
            try jobListener.start(
                port: network.listenPort,
                destinationRoot: access.url,
                applier: permissionApplier,
                onIndexUpdate: { [weak self] received in
                    Task { @MainActor in
                        guard let self else { return }
                        ReceiveIndex.upsert(
                            &self.fileIndex,
                            destinationRootPath: receivePath,
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
