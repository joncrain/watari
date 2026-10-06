import AppKit
import Foundation
import Network
import SwiftUI
import UniformTypeIdentifiers
import WatariCore
import os.log

private let modelLog = Logger(subsystem: "app.watari.mac", category: "AppModel")

@MainActor
final class AppModel: ObservableObject {
    enum Phase: Equatable {
        /// Destination-primary: connect to a source Mac first.
        case needsConnect
        /// Peer connected; browsing their offered folder catalog.
        case browsingOffers
        case previewReady
        case copying
        case finishedWithExceptions
        case peerGone
    }

    @Published var phase: Phase = .needsConnect
    /// Folders this Mac offers when acting as source (whitelist + optional Settings adds).
    @Published var offeredFolders: [BookmarkEntry] = []
    @Published var receiveFolder: BookmarkEntry?
    @Published var peers: [PeerRecord] = []
    @Published var selectedPeerID: PeerRecord.ID?
    /// Catalog from the connected source peer.
    @Published var peerOffers: [OfferedRoot] = []
    @Published var peerOfferDisplayName: String = ""
    /// Display names selected from `peerOffers` to pull.
    @Published var selectedOfferNames: Set<String> = []
    @Published var previewSummary: PreviewSummary?
    @Published var selectedPreviewPath: String?
    @Published var policy: PermissionPolicy = .default
    @Published var conflict: ConflictPolicy = .default
    @Published var dlp: DLPPolicy = ManagedDefaults.dlpPolicy()
    @Published var network: NetworkConfig = .default
    @Published var jobLog = JobLog()
    @Published var statusMessage: String = "Connect to another Mac to choose what to transfer."
    @Published var progressFraction: Double = 0
    @Published var showConnectSheet = false
    @Published var libraryWarning: String?
    @Published var lastError: String?
    @Published var indexedBytes: UInt64 = 0
    @Published var peerInventoryAvailable = false
    @Published var isRefreshingOffers = false

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
    private var peerSourceEntries: [FileMetadata] = []
    private var receiveAccessURL: URL?
    private var offeredAccessURLs: [URL] = []
    private let indexURL: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return base.appendingPathComponent("Watari", isDirectory: true)
            .appendingPathComponent("local-index.json")
    }()

    var canPreview: Bool {
        selectedPeerID != nil
            && !selectedOfferNames.isEmpty
            && phase != .copying
            && phase != .needsConnect
    }

    /// Start pulls selected folders; Preview is optional but recommended.
    var canStart: Bool {
        selectedPeerID != nil
            && !selectedOfferNames.isEmpty
            && phase != .copying
            && phase != .needsConnect
    }

    var canStop: Bool { phase == .copying }
    var exceptionCount: Int { previewSummary?.permissionExceptionCount ?? 0 }
    var isListening: Bool { jobListener.isListening }

    /// Why Preview is disabled (nil when enabled).
    var previewBlockedReason: String? {
        if canPreview { return nil }
        if phase == .copying { return "Transfer in progress." }
        if selectedPeerID == nil || phase == .needsConnect { return "Connect to a source Mac first." }
        if selectedOfferNames.isEmpty { return "Select at least one folder to transfer." }
        return nil
    }

    /// Why Start is disabled (nil when enabled).
    var startBlockedReason: String? {
        if canStart { return nil }
        if phase == .copying { return "Transfer in progress." }
        if selectedPeerID == nil || phase == .needsConnect { return "Connect to a source Mac first." }
        if selectedOfferNames.isEmpty { return "Select at least one folder to transfer." }
        return nil
    }

    var usesHomeReceiveMapping: Bool { receiveFolder == nil }

    var destinationHomeURL: URL {
        FileManager.default.homeDirectoryForCurrentUser.standardizedFileURL
    }

    /// Selected offers mapped onto this Mac (home-relative by default).
    func effectiveDestinationRoots() -> [String: URL] {
        let selected = peerOffers.filter { selectedOfferNames.contains($0.name) }
        let override = receiveFolder.map { URL(fileURLWithPath: $0.path, isDirectory: true) }
        return HomePathMapper.destinationRoots(
            offers: selected,
            destinationHome: destinationHomeURL,
            overrideParent: override
        )
    }

    func receiveMappingLabels() -> [(name: String, destinationPath: String)] {
        let selected = peerOffers.filter { selectedOfferNames.contains($0.name) }
        let override = receiveFolder.map { URL(fileURLWithPath: $0.path, isDirectory: true) }
        return HomePathMapper.mappingLabels(
            offers: selected,
            destinationHome: destinationHomeURL,
            overrideParent: override
        )
    }

    func offeredBytes(for folder: BookmarkEntry) -> UInt64 {
        fileIndex.totalBytes(rootPath: folder.path)
    }

    func clearReceiveFolderOverride() {
        receiveFolder = nil
        statusMessage = "Receiving into matching folders under your home directory."
    }

    var selectedPeer: PeerRecord? {
        peers.first { $0.id == selectedPeerID }
    }

    var selectedPreviewItem: PreviewItem? {
        guard let path = selectedPreviewPath else { return nil }
        return previewSummary?.items.first { $0.relativePath == path }
    }

    var selectedOfferBytes: UInt64 {
        peerOffers
            .filter { selectedOfferNames.contains($0.name) }
            .reduce(UInt64(0)) { $0 + $1.totalBytes }
    }

    init() {
        if let loaded = try? LocalFileIndex.load(from: indexURL) {
            fileIndex = loaded
            indexedBytes = loaded.totalBytes()
        }
        bootstrapOfferedWhitelist()
    }

    // MARK: - Destination: peer offers

    func isOfferSelected(_ name: String) -> Bool {
        selectedOfferNames.contains(name)
    }

    func setOfferSelected(_ selected: Bool, name: String) {
        if selected {
            selectedOfferNames.insert(name)
        } else {
            selectedOfferNames.remove(name)
        }
        previewSummary = nil
        if phase == .previewReady || phase == .finishedWithExceptions {
            phase = .browsingOffers
            statusMessage = "Selection changed. Run Preview again."
        }
    }

    func setOffersSelected(_ selected: Bool, names: [String]) {
        if selected {
            selectedOfferNames.formUnion(names)
        } else {
            selectedOfferNames.subtract(names)
        }
        previewSummary = nil
        if phase == .previewReady || phase == .finishedWithExceptions {
            phase = .browsingOffers
        }
    }

    func refreshPeerOffers() {
        guard let peer = selectedPeer else { return }
        isRefreshingOffers = true
        statusMessage = "Asking \(peer.displayName) for offered folders…"
        Task {
            do {
                let catalog = try await transfer.fetchOfferCatalog(peer: peer, connector: peerConnector)
                await MainActor.run {
                    self.peerOffers = catalog.roots.sorted {
                        $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
                    }
                    self.peerOfferDisplayName = catalog.displayName
                    self.selectedOfferNames = self.selectedOfferNames.intersection(Set(catalog.roots.map(\.name)))
                    self.phase = .browsingOffers
                    self.isRefreshingOffers = false
                    if catalog.roots.isEmpty {
                        self.statusMessage = "\(catalog.displayName) isn’t offering folders yet. On that Mac, enable Listen and offer folders in Settings."
                    } else {
                        self.statusMessage = "Connected to \(catalog.displayName). Choose folders to transfer here."
                    }
                }
            } catch {
                await MainActor.run {
                    self.isRefreshingOffers = false
                    self.lastError = error.localizedDescription
                    self.statusMessage = "Couldn’t load offered folders — \(error.localizedDescription)"
                    modelLog.error("offer catalog failed: \(error.localizedDescription, privacy: .public)")
                }
            }
        }
    }

    // MARK: - Source: offer folders on this Mac

    /// Ensure default whitelist folders are offered (no open panel).
    func bootstrapOfferedWhitelist() {
        let home = bookmarkStore.homeDirectory
        for name in TransferNode.allowedNames {
            let url = home.appendingPathComponent(name, isDirectory: true)
            if offeredFolders.contains(where: { $0.path == url.path }) { continue }
            do {
                let entry = try bookmarkStore.bookmarkWhitelistedFolder(url)
                offeredFolders.append(entry)
            } catch {
                modelLog.info("Skip offering \(name, privacy: .public): \(error.localizedDescription, privacy: .public)")
            }
        }
        reindexOfferedFolders()
    }

    /// Settings escape hatch: offer an extra folder from this Mac (source role).
    func addOfferedFolder() {
        guard let url = bookmarkStore.pickFolder(
            message: "Choose a folder this Mac should offer to connected peers."
        ) else { return }
        do {
            let entry = try bookmarkStore.save(url: url)
            if offeredFolders.contains(where: { $0.path == entry.path }) {
                statusMessage = "\(entry.displayName) is already offered."
                return
            }
            offeredFolders.append(entry)
            libraryWarning = Denylist().warningForSelectingLibraryRoot(entry.path)
            reindexOfferedFolders()
            refreshListener()
            statusMessage = "Offering \(entry.displayName) to peers."
        } catch {
            lastError = error.localizedDescription
        }
    }

    func removeOfferedFolder(_ id: BookmarkEntry.ID) {
        if let entry = offeredFolders.first(where: { $0.id == id }) {
            fileIndex.roots.removeValue(forKey: entry.path)
            persistIndex()
        }
        offeredFolders.removeAll { $0.id == id }
        refreshListener()
    }

    func reindexOfferedFolders() {
        for folder in offeredFolders {
            do {
                let access = try bookmarkStore.startAccessRefreshing(folder)
                defer { bookmarkStore.stopAccess(to: access.url) }
                let scanned = try FileScanner.scan(
                    root: access.url,
                    displayRoot: access.entry.displayName,
                    denylist: Denylist(),
                    hashContents: false
                )
                fileIndex.replace(rootPath: access.entry.path, metadata: scanned.entries)
            } catch {
                modelLog.error("Index failed for \(folder.path, privacy: .public): \(error.localizedDescription, privacy: .public)")
            }
        }
        persistIndex()
    }

    func chooseReceiveFolder() {
        guard let url = bookmarkStore.pickFolder(
            message: "Advanced: choose a single parent folder. Offered roots arrive as subfolders here instead of matching your home layout."
        ) else { return }
        do {
            receiveFolder = try bookmarkStore.save(url: url)
            refreshListener()
            statusMessage = "Advanced receive override: \(url.lastPathComponent)."
        } catch {
            lastError = error.localizedDescription
        }
    }

    func reauthorizeFolder(_ id: BookmarkEntry.ID) {
        guard let index = offeredFolders.firstIndex(where: { $0.id == id }) else { return }
        do {
            let updated = try bookmarkStore.reauthorize(entry: offeredFolders[index])
            offeredFolders[index] = updated
            statusMessage = "Re-authorized \(updated.displayName)."
            reindexOfferedFolders()
            refreshListener()
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

    // MARK: - Preview / pull

    func preview() {
        guard canPreview, let peer = selectedPeer else {
            lastError = previewBlockedReason ?? "Can’t preview yet."
            return
        }
        statusMessage = "Asking \(peer.displayName) for file inventory…"
        let rootNames = Array(selectedOfferNames).sorted()
        let conflictPolicy = conflict
        let permissionPolicy = policy
        let dlpPolicy = dlp
        Task {
            do {
                let sources = try await transfer.fetchInventory(
                    rootNames: rootNames,
                    peer: peer,
                    connector: peerConnector
                )

                var destinations: [String: FileMetadata] = [:]
                var inventoryOK = true
                let roots = await MainActor.run { self.effectiveDestinationRoots() }
                if !roots.isEmpty {
                    let local = try DestinationInventory.scan(roots: roots, denylist: Denylist())
                    destinations = InventoryResponsePayload(entries: local).asDestinationMap
                }

                let receiving = permissionApplier.currentIdentity()
                let summary = PreviewDiff.build(
                    sources: sources,
                    destinations: destinations,
                    skipped: [],
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
                    self.peerSourceEntries = sources
                    self.peerInventoryAvailable = inventoryOK
                    self.previewSummary = summary
                    self.jobLog = log
                    self.selectedPreviewPath = summary.items.first?.relativePath
                    self.phase = .previewReady
                    self.statusMessage =
                        "Preview ready — \(summary.copy) copy, \(summary.update) update, \(summary.unchanged) unchanged, \(summary.keepBoth) keep both, \(summary.skip) skip"
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
        guard canStart, let peer = selectedPeer else {
            lastError = startBlockedReason ?? "Can’t start transfer yet."
            return
        }
        let rootNames = Array(selectedOfferNames).sorted()
        let destinationRoots = effectiveDestinationRoots()
        guard !destinationRoots.isEmpty else {
            lastError = "No destination folders to receive into."
            return
        }
        // Ensure remap-to-receiving-user stays the default ownership story on apply.
        if !policy.remapOwnerToReceivingUser {
            statusMessage = "Pulling with source ownership preserved (advanced)."
        }
        phase = .copying
        statusMessage = "Pulling from \(peer.displayName)…"
        progressFraction = 0
        let conflictPolicy = conflict
        let permissionPolicy = policy
        let overrideEntry = receiveFolder
        let indexRootPath = overrideEntry?.path ?? destinationHomeURL.path
        Task {
            do {
                var overrideAccessURL: URL?
                if let overrideEntry {
                    let access = try bookmarkStore.startAccessRefreshing(overrideEntry)
                    overrideAccessURL = access.url
                    if access.didRefresh {
                        await MainActor.run { self.receiveFolder = access.entry }
                    }
                }
                defer {
                    if let overrideAccessURL {
                        bookmarkStore.stopAccess(to: overrideAccessURL)
                    }
                }
                try await transfer.pull(
                    rootNames: rootNames,
                    peer: peer,
                    policy: permissionPolicy,
                    conflict: conflictPolicy,
                    destinationRoots: destinationRoots,
                    connector: peerConnector,
                    applier: permissionApplier,
                    onIndexUpdate: { [weak self] received in
                        Task { @MainActor in
                            guard let self else { return }
                            ReceiveIndex.upsert(
                                &self.fileIndex,
                                destinationRootPath: indexRootPath,
                                received: received
                            )
                            self.persistIndex()
                        }
                    }
                ) { @Sendable [weak self] fraction, message in
                    Task { @MainActor in
                        self?.progressFraction = fraction
                        if let message { self?.statusMessage = message }
                    }
                }
                await MainActor.run {
                    self.phase = (self.exceptionCount > 0) ? .finishedWithExceptions : .browsingOffers
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
                    self.phase = .browsingOffers
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
        phase = .browsingOffers
        statusMessage = "Peer connected. Loading offered folders…"
        refreshPeerOffers()
    }

    func refreshListener() {
        jobListener.stop()
        if let receiveAccessURL {
            bookmarkStore.stopAccess(to: receiveAccessURL)
            self.receiveAccessURL = nil
        }
        for url in offeredAccessURLs {
            bookmarkStore.stopAccess(to: url)
        }
        offeredAccessURLs = []

        guard network.listenEnabled else { return }

        var receiveURL: URL?
        if let receive = receiveFolder {
            do {
                let access = try bookmarkStore.startAccessRefreshing(receive)
                if access.didRefresh {
                    receiveFolder = access.entry
                }
                receiveAccessURL = access.url
                receiveURL = access.url
            } catch {
                lastError = error.localizedDescription
            }
        }

        var offeredRoots: [String: URL] = [:]
        var catalogRoots: [(name: String, path: String)] = []
        for folder in offeredFolders {
            do {
                let access = try bookmarkStore.startAccessRefreshing(folder)
                if access.didRefresh,
                   let idx = offeredFolders.firstIndex(where: { $0.id == access.entry.id }) {
                    offeredFolders[idx] = access.entry
                }
                offeredAccessURLs.append(access.url)
                offeredRoots[access.entry.displayName] = access.url
                catalogRoots.append((access.entry.displayName, access.entry.path))
            } catch {
                modelLog.error("Offer root unavailable \(folder.path, privacy: .public): \(error.localizedDescription, privacy: .public)")
            }
        }

        let catalog = OfferCatalogResponsePayload(
            displayName: Host.current().localizedName ?? "Watari Mac",
            roots: SourceOffer.catalog(displayRoots: catalogRoots, index: fileIndex)
        )

        guard receiveURL != nil || !offeredRoots.isEmpty else { return }

        let advertiseBonjour = nearbyDiscoveryAllowed
        do {
            try jobListener.start(
                port: network.listenPort,
                receiveRoot: receiveURL,
                offeredRoots: offeredRoots,
                offerCatalog: catalog,
                advertiseBonjour: advertiseBonjour,
                applier: permissionApplier,
                onIndexUpdate: { [weak self] received in
                    Task { @MainActor in
                        guard let self, let receive = self.receiveFolder else { return }
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

    /// Nearby / Bonjour is allowed unless discovery is off/explicit-only or Managed denies it.
    var nearbyDiscoveryAllowed: Bool {
        network.discoveryMode == .nearby && !ManagedDefaults.denyBonjour
    }

    /// Pair to host/port and move into the offer-catalog phase (one TLS socket).
    func connectAndBrowse(
        host: String,
        port: Int,
        displayName: String,
        pairingCode: String = ""
    ) async throws {
        let name = displayName.isEmpty ? host : displayName
        let (record, connection) = try await peerConnector.pairKeepingConnection(
            host: host,
            port: port,
            displayName: name,
            pairingCode: pairingCode
        )
        try await finishConnect(record: record, connection: connection)
    }

    /// Nearby: pair via Bonjour service endpoint (no pre-resolve to IP).
    func connectAndBrowse(bonjour peer: BonjourPeer, pairingCode: String = "") async throws {
        let (record, connection) = try await peerConnector.pairKeepingConnection(
            bonjour: peer,
            pairingCode: pairingCode
        )
        try await finishConnect(record: record, connection: connection)
    }

    private func finishConnect(record: PeerRecord, connection: NWConnection) async throws {
        defer { connection.cancel() }
        peers.append(record)
        selectedPeerID = record.id
        showConnectSheet = false
        phase = .browsingOffers
        statusMessage = "Peer connected. Loading offered folders…"
        isRefreshingOffers = true
        do {
            let catalog = try await transfer.fetchOfferCatalog(on: connection)
            peerOffers = catalog.roots.sorted {
                $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
            }
            peerOfferDisplayName = catalog.displayName
            selectedOfferNames = selectedOfferNames.intersection(Set(catalog.roots.map(\.name)))
            isRefreshingOffers = false
            if catalog.roots.isEmpty {
                statusMessage = "\(catalog.displayName) isn’t offering folders yet. On that Mac, enable Listen and offer folders in Settings."
            } else {
                statusMessage = "Connected to \(catalog.displayName). Choose folders to transfer here."
            }
        } catch {
            isRefreshingOffers = false
            lastError = error.localizedDescription
            statusMessage = "Couldn’t load offered folders — \(error.localizedDescription)"
            modelLog.error("offer catalog failed: \(error.localizedDescription, privacy: .public)")
            throw error
        }
    }

    private func adoptConnectedPeer(_ record: PeerRecord) {
        peers.append(record)
        selectedPeerID = record.id
        showConnectSheet = false
        phase = .browsingOffers
        statusMessage = "Peer connected. Loading offered folders…"
        refreshPeerOffers()
    }

    private func persistIndex() {
        indexedBytes = fileIndex.totalBytes()
        try? fileIndex.save(to: indexURL)
    }
}
