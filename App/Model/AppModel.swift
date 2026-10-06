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
        case transferComplete
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
    /// Source Mac Dock layout from the offer catalog (live preview).
    @Published var peerDockApps: [DockAppOffer] = []
    /// Include source Dock in the unified Start transfer plan.
    @Published var selectedDockTransfer = false
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
    /// User opened “Offer folders…” or an inbound peer connected while listening.
    @Published var showSourcePrep = false
    @Published var inboundPeerConnected = false
    @Published var lastTransferSummary: TransferCompleteSummary?
    /// Overlapping inbound TLS sessions (pair+catalog may open more than one briefly).
    private var inboundConnectionCount = 0

    var shouldShowSourcePrep: Bool {
        (showSourcePrep || inboundPeerConnected)
            && selectedPeerID == nil
            && phase != .transferComplete
            && phase != .copying
    }
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

    /// True when Dock is checked and the source sent a layout.
    var willApplyDock: Bool {
        selectedDockTransfer && !peerDockApps.isEmpty
    }

    /// Start runs the whole transfer plan: selected folders and/or checked Services.
    var canStart: Bool {
        selectedPeerID != nil
            && phase != .copying
            && phase != .needsConnect
            && (!selectedOfferNames.isEmpty || willApplyDock)
    }

    var canStop: Bool { phase == .copying }
    var exceptionCount: Int { previewSummary?.permissionExceptionCount ?? 0 }
    var isListening: Bool { jobListener.isListening }

    /// Why Start is disabled (nil when enabled).
    var startBlockedReason: String? {
        if canStart { return nil }
        if phase == .copying { return "Transfer in progress." }
        if selectedPeerID == nil || phase == .needsConnect { return "Connect to a source Mac first." }
        if selectedOfferNames.isEmpty && !willApplyDock {
            if selectedDockTransfer && peerDockApps.isEmpty {
                return "Dock is checked but the source hasn’t sent a Dock layout yet."
            }
            return "Select at least one folder or Service (Dock) to transfer."
        }
        return nil
    }

    func setDockTransferSelected(_ selected: Bool) {
        selectedDockTransfer = selected
    }

    var usesHomeReceiveMapping: Bool { receiveFolder == nil }

    var destinationHomeURL: URL {
        // Real user home — not the sandbox container path.
        bookmarkStore.homeDirectory
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
        if phase == .previewReady || phase == .finishedWithExceptions || phase == .transferComplete {
            phase = .browsingOffers
            statusMessage = "Selection changed."
        }
    }

    func setOffersSelected(_ selected: Bool, names: [String]) {
        if selected {
            selectedOfferNames.formUnion(names)
        } else {
            selectedOfferNames.subtract(names)
        }
        previewSummary = nil
        if phase == .previewReady || phase == .finishedWithExceptions || phase == .transferComplete {
            phase = .browsingOffers
        }
    }

    func applyOfferCatalog(_ catalog: OfferCatalogResponsePayload) {
        peerOffers = catalog.roots.sorted {
            $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }
        peerOfferDisplayName = catalog.displayName
        peerDockApps = catalog.dockApps
        selectedOfferNames = selectedOfferNames.intersection(Set(catalog.roots.map(\.name)))
        // Default Dock into the transfer plan when the source sends a layout.
        if !catalog.dockApps.isEmpty {
            selectedDockTransfer = true
        } else {
            selectedDockTransfer = false
        }
        phase = .browsingOffers
        modelLog.info(
            "Received catalog from \(catalog.displayName, privacy: .public): \(catalog.roots.count, privacy: .public) root(s) [\(catalog.roots.map(\.name).joined(separator: ", "), privacy: .public)], dockApps=\(catalog.dockApps.count, privacy: .public)"
        )
        if catalog.roots.isEmpty && catalog.dockApps.isEmpty {
            statusMessage = "\(catalog.displayName) isn’t offering folders or Dock yet. On that Mac, enable Listen."
        } else {
            statusMessage = "Connected to \(catalog.displayName). Choose folders and Services, then Start."
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
                    self.applyOfferCatalog(catalog)
                    self.isRefreshingOffers = false
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

    /// Ensure default whitelist folders that exist are offered (no open panel).
    /// Re-runs safely: restores any removed defaults and repairs whitelist
    /// entries that were incorrectly stored as security-scoped bookmarks.
    func bootstrapOfferedWhitelist() {
        let home = bookmarkStore.homeDirectory
        for name in TransferNode.allowedNames {
            let url = home.appendingPathComponent(name, isDirectory: true)
            if let idx = offeredFolders.firstIndex(where: { $0.path == url.path }) {
                // Repair: whitelist must use home-relative exception access.
                if offeredFolders[idx].access != .homeRelativeException {
                    modelLog.info("Repairing whitelist access for \(name, privacy: .public)")
                    if let repaired = try? bookmarkStore.bookmarkWhitelistedFolder(url) {
                        offeredFolders[idx] = BookmarkEntry(
                            id: offeredFolders[idx].id,
                            displayName: repaired.displayName,
                            path: repaired.path,
                            bookmarkData: repaired.bookmarkData,
                            access: .homeRelativeException
                        )
                    }
                }
                continue
            }
            do {
                let entry = try bookmarkStore.bookmarkWhitelistedFolder(url)
                offeredFolders.append(entry)
            } catch {
                modelLog.info("Skip offering \(name, privacy: .public): \(error.localizedDescription, privacy: .public)")
            }
        }
        // Stable order: whitelist names first, then custom Add folder entries.
        let rank = Dictionary(uniqueKeysWithValues: TransferNode.allowedNames.enumerated().map { ($1, $0) })
        offeredFolders.sort { a, b in
            let ra = rank[a.displayName] ?? 1_000
            let rb = rank[b.displayName] ?? 1_000
            if ra != rb { return ra < rb }
            return a.displayName.localizedCaseInsensitiveCompare(b.displayName) == .orderedAscending
        }
        reindexOfferedFolders()
        modelLog.info("Offering \(self.offeredFolders.count, privacy: .public) folder(s): \(self.offeredFolders.map(\.displayName).joined(separator: ", "), privacy: .public)")
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
            lastError = "Nothing to export yet — run a transfer or wait for permission notes."
            return
        }
        do {
            let data = try log.jsonLinesData()
            let panel = NSSavePanel()
            panel.allowedContentTypes = [.json]
            panel.nameFieldStringValue = "watari-exceptions.jsonl"
            panel.message = "Export transfer actions and permission exceptions (JSON Lines)."
            guard panel.runModal() == .OK, let url = panel.url else { return }
            try data.write(to: url, options: .atomic)
            statusMessage = "Exported \(log.exceptionEvents.count) exception(s), \(log.events.count) event(s)."
            jobLog = log
        } catch {
            lastError = error.localizedDescription
        }
    }

    // MARK: - Pull

    /// Internal inventory dry-run used by Start’s transfer path and exception export.
    /// Not exposed in the UI.
    func preview() {
        guard canStart, let peer = selectedPeer else {
            lastError = startBlockedReason ?? "Can’t inventory yet."
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
                        "Inventory ready — \(summary.copy) copy, \(summary.update) update, \(summary.unchanged) unchanged, \(summary.keepBoth) keep both, \(summary.skip) skip"
                }
            } catch {
                await MainActor.run {
                    self.lastError = error.localizedDescription
                    self.statusMessage = "Inventory failed — \(error.localizedDescription)"
                }
            }
        }
    }

    func dismissTransferSummary(keepPeer: Bool = false) {
        lastTransferSummary = nil
        progressFraction = 0
        if keepPeer, selectedPeerID != nil {
            phase = .browsingOffers
            statusMessage = "Choose folders and Services, then Start."
        } else {
            selectedPeerID = nil
            selectedOfferNames = []
            peerOffers = []
            peerDockApps = []
            selectedDockTransfer = false
            phase = .needsConnect
            statusMessage = "Connect to another Mac to choose what to transfer."
        }
    }

    func start() {
        guard canStart, let peer = selectedPeer else {
            lastError = startBlockedReason ?? "Can’t start transfer yet."
            return
        }
        let rootNames = Array(selectedOfferNames).sorted()
        let applyDock = willApplyDock
        let dockApps = peerDockApps
        let destinationRoots = rootNames.isEmpty ? [:] : effectiveDestinationRoots()
        if !rootNames.isEmpty, destinationRoots.isEmpty {
            lastError = "No destination folders to receive into."
            return
        }
        if applyDock, dockApps.isEmpty {
            lastError = DockApplyError.emptyLayout.localizedDescription
            return
        }

        phase = .copying
        progressFraction = 0
        if rootNames.isEmpty, applyDock {
            statusMessage = "Applying Dock from \(peer.displayName)…"
        } else if applyDock {
            statusMessage = "Pulling folders and applying Dock from \(peer.displayName)…"
        } else {
            statusMessage = "Pulling from \(peer.displayName)…"
        }
        if !policy.remapOwnerToReceivingUser, !rootNames.isEmpty {
            statusMessage = "Pulling with source ownership preserved (advanced)."
        }

        let conflictPolicy = conflict
        let permissionPolicy = policy
        let overrideEntry = receiveFolder
        let indexRootPath = overrideEntry?.path ?? destinationHomeURL.path
        let previewSnapshot = previewSummary
        let startedAt = Date()
        let peerName = peer.displayName
        Task {
            do {
                let receivedBox = ReceivedBox()
                if !rootNames.isEmpty {
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
                            receivedBox.items = received
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
                            // Leave headroom for Dock apply after the pull.
                            let scale = applyDock ? 0.9 : 1.0
                            self?.progressFraction = fraction * scale
                            if let message { self?.statusMessage = message }
                        }
                    }
                }

                var dockCount = 0
                var dockError: String?
                if applyDock {
                    await MainActor.run {
                        self.statusMessage = "Applying Dock layout…"
                        self.progressFraction = max(self.progressFraction, 0.92)
                    }
                    do {
                        dockCount = try DockApplier.apply(apps: dockApps)
                    } catch {
                        dockError = error.localizedDescription
                        modelLog.error("Dock apply failed: \(error.localizedDescription, privacy: .public)")
                    }
                }

                await MainActor.run {
                    let duration = Date().timeIntervalSince(startedAt)
                    let receivedItems = receivedBox.items
                    let files = receivedItems.filter { !$0.isDirectory }.count
                    let bytes = receivedItems.reduce(UInt64(0)) { $0 + $1.size }
                    let remaps = previewSnapshot?.items.reduce(0) { partial, item in
                        partial + item.permissionExceptions.filter { $0.code == .ownerRemapped }.count
                    } ?? 0
                    let notes = previewSnapshot?.permissionExceptionCount ?? remaps
                    let dockOK = applyDock && dockError == nil
                    let summary = TransferCompleteSummary(
                        peerDisplayName: peerName,
                        folderNames: rootNames,
                        filesTransferred: files,
                        bytesTransferred: bytes,
                        durationSeconds: duration,
                        skipped: previewSnapshot?.skip ?? 0,
                        unchanged: previewSnapshot?.unchanged ?? 0,
                        permissionRemaps: remaps,
                        permissionNotes: notes,
                        hadExceptions: notes > 0 || remaps > 0 || dockError != nil,
                        dockApplied: dockOK,
                        dockAppCount: dockOK ? dockCount : 0
                    )
                    self.lastTransferSummary = summary
                    self.phase = .transferComplete
                    self.progressFraction = 1
                    if let dockError {
                        self.lastError = "Folders finished, but Dock apply failed: \(dockError)"
                        self.statusMessage = "Finished with Dock apply error."
                    } else if summary.hadExceptions {
                        self.statusMessage = "Finished with permission notes."
                    } else {
                        self.statusMessage = "Transfer complete."
                    }
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

        // Always restore default whitelist folders that exist before advertising.
        bootstrapOfferedWhitelist()

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
                // Still advertise existing whitelist paths so the destination
                // catalog isn’t silently reduced to a single readable folder.
                let url = URL(fileURLWithPath: folder.path, isDirectory: true)
                var isDir: ObjCBool = false
                if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir), isDir.boolValue,
                   BookmarkStore.whitelistedHomeFolderNames.contains(folder.displayName) {
                    modelLog.error(
                        "Offer root access weak \(folder.path, privacy: .public): \(error.localizedDescription, privacy: .public) — still cataloging"
                    )
                    offeredRoots[folder.displayName] = url
                    catalogRoots.append((folder.displayName, folder.path))
                } else {
                    modelLog.error("Offer root unavailable \(folder.path, privacy: .public): \(error.localizedDescription, privacy: .public)")
                }
            }
        }

        let dockApps = DockReader.currentApps()
        let catalog = OfferCatalogResponsePayload(
            displayName: Host.current().localizedName ?? "Watari Mac",
            roots: SourceOffer.catalog(displayRoots: catalogRoots, index: fileIndex),
            dockApps: dockApps
        )
        modelLog.info(
            "Listen catalog: \(catalog.roots.count, privacy: .public) root(s) [\(catalog.roots.map(\.name).joined(separator: ", "), privacy: .public)], dockApps=\(dockApps.count, privacy: .public)"
        )
        let catalogRootsCopy = catalogRoots
        let fileIndexSnapshot = fileIndex
        let catalogProvider: @Sendable () -> OfferCatalogResponsePayload = {
            let liveDock = DockReader.currentApps()
            let payload = OfferCatalogResponsePayload(
                displayName: Host.current().localizedName ?? "Watari Mac",
                roots: SourceOffer.catalog(displayRoots: catalogRootsCopy, index: fileIndexSnapshot),
                dockApps: liveDock
            )
            modelLog.info(
                "Serve catalog: \(payload.roots.count, privacy: .public) root(s), dockApps=\(liveDock.count, privacy: .public)"
            )
            return payload
        }

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
                },
                onClientConnected: { [weak self] in
                    Task { @MainActor in
                        guard let self else { return }
                        self.inboundConnectionCount += 1
                        self.inboundPeerConnected = true
                        if self.selectedPeerID == nil {
                            self.showSourcePrep = true
                            self.statusMessage = "A Mac connected — confirm folders you’re offering."
                        }
                    }
                },
                onClientDisconnected: { [weak self] in
                    Task { @MainActor in
                        guard let self else { return }
                        self.inboundConnectionCount = max(0, self.inboundConnectionCount - 1)
                        self.inboundPeerConnected = self.inboundConnectionCount > 0
                        if !self.inboundPeerConnected, self.selectedPeerID == nil, self.showSourcePrep {
                            self.statusMessage = "Peer disconnected. Listening for another connection."
                        }
                    }
                },
                offerCatalogProvider: catalogProvider
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
        showSourcePrep = false
        showConnectSheet = false
        phase = .browsingOffers
        statusMessage = "Peer connected. Loading offered folders…"
        isRefreshingOffers = true
        do {
            let catalog = try await transfer.fetchOfferCatalog(on: connection)
            applyOfferCatalog(catalog)
            isRefreshingOffers = false
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
        showSourcePrep = false
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

/// Mutable bag so pull’s index callback can hand received metadata back to Start.
private final class ReceivedBox: @unchecked Sendable {
    var items: [FileMetadata] = []
}
