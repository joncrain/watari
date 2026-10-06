import SwiftUI
import WatariCore

/// Preparation screen: offer folders when Listen is on; connect to pull from another Mac.
struct ConnectFirstView: View {
    @EnvironmentObject private var model: AppModel

    @State private var nearby: [BonjourPeer] = []
    @State private var connectingID: String?
    @State private var errorText: String?

    private var nearbyAllowed: Bool { model.nearbyDiscoveryAllowed }

    var body: some View {
        ScrollView {
            VStack(spacing: 0) {
                Text(model.network.listenEnabled ? "Prepare this Mac" : "Connect to a Mac")
                    .font(.title2.weight(.semibold))
                    .padding(.top, 28)

                Text(headerSubtitle)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 440)
                    .padding(.top, 8)
                    .padding(.horizontal, 32)

                if let errorText {
                    Text(errorText)
                        .font(.callout)
                        .foregroundStyle(.red)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 420)
                        .padding(.top, 12)
                        .padding(.horizontal, 32)
                }

                // Source owns the offer catalog — visible whenever Listen is on.
                sourceOfferSection
                    .frame(maxWidth: 540, alignment: .leading)
                    .padding(.top, 22)
                    .padding(.horizontal, 40)

                pullSection
                    .frame(maxWidth: 540, alignment: .leading)
                    .padding(.top, 28)
                    .padding(.horizontal, 40)
                    .padding(.bottom, 32)
            }
            .frame(maxWidth: .infinity)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear { startBrowsingIfNeeded() }
        .onDisappear { model.bonjour.stop() }
        .onChange(of: model.network.discoveryMode) { _, _ in
            startBrowsingIfNeeded()
        }
        .onChange(of: model.network.listenEnabled) { _, enabled in
            model.refreshListener()
            if enabled { startBrowsingIfNeeded() }
        }
    }

    private var headerSubtitle: String {
        if model.network.listenEnabled {
            return "Offer folders for another Mac to pull, or connect to pull from a Mac that is offering."
        }
        return "Watari pulls folders from another Mac that is offering them. Turn on Listen below to offer folders from this Mac."
    }

    // MARK: - Source offers

    private var sourceOfferSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Text("Offer from this Mac")
                    .font(.headline)
                Spacer()
                if model.network.listenEnabled {
                    Text(model.isListening
                         ? "Listening on \(model.network.listenPort)"
                         : "Listen on — starting…")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Toggle("Listen for peers", isOn: $model.network.listenEnabled)
                .help("When on, nearby Macs can connect and see the folders you offer.")

            if model.network.listenEnabled {
                Text("Peers see this catalog when they Connect. Add folders here — the destination only chooses what to pull.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                borderedOfferList

                HStack {
                    Button("Add folder…") { model.addOfferedFolder() }
                    Button("Reindex") {
                        model.reindexOfferedFolders()
                        model.refreshListener()
                    }
                    .help("Refresh folder sizes for peers")
                    Spacer()
                }
            } else {
                Text("Turn on Listen to advertise offered folders and accept connections.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var borderedOfferList: some View {
        VStack(alignment: .leading, spacing: 0) {
            if model.offeredFolders.isEmpty {
                Text("No folders offered yet. Add a folder to share.")
                    .foregroundStyle(.secondary)
                    .padding(12)
            } else {
                ForEach(Array(model.offeredFolders.enumerated()), id: \.element.id) { index, folder in
                    HStack(spacing: 10) {
                        Image(systemName: symbol(for: folder.displayName))
                            .foregroundStyle(.secondary)
                            .frame(width: 18)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(folder.displayName)
                            Text(folder.path)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                        Spacer(minLength: 8)
                        Text(
                            ByteCountFormatter.string(
                                fromByteCount: Int64(model.offeredBytes(for: folder)),
                                countStyle: .file
                            )
                        )
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .contextMenu {
                        Button("Re-authorize…") { model.reauthorizeFolder(folder.id) }
                        Button("Remove", role: .destructive) { model.removeOfferedFolder(folder.id) }
                    }
                    if index < model.offeredFolders.count - 1 {
                        Divider().padding(.leading, 40)
                    }
                }
            }
        }
        .background(Color(nsColor: .textBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .strokeBorder(Color(nsColor: .separatorColor), lineWidth: 1)
        )
    }

    // MARK: - Destination connect

    private var pullSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Pull from another Mac")
                .font(.headline)

            Text(footerHint)
                .font(.caption)
                .foregroundStyle(.secondary)

            if nearbyAllowed {
                nearbySection
            }

            if !model.peers.isEmpty {
                pairedSection
            }

            if nearbyAllowed {
                Button {
                    model.showConnectSheet = true
                } label: {
                    Label("Connect by host / port…", systemImage: "network")
                }
                .buttonStyle(.bordered)
                .controlSize(.large)
            } else {
                Button {
                    model.showConnectSheet = true
                } label: {
                    Label("Connect…", systemImage: "link")
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .keyboardShortcut(.defaultAction)
            }
        }
    }

    private var footerHint: String {
        if nearbyAllowed {
            return "On the other Mac: Listen on, offer at least one folder, leave Watari open."
        }
        return "Nearby is off (Settings or Managed). Connect with hostname or IP. Source Mac needs Listen on."
    }

    private var nearbySection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Nearby")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .textCase(.uppercase)

            if nearby.isEmpty {
                HStack(spacing: 8) {
                    ProgressView()
                        .controlSize(.small)
                    Text("Looking for Macs on this network…")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 10)
                .padding(.horizontal, 12)
                .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 8))
            } else {
                VStack(spacing: 0) {
                    ForEach(nearby) { peer in
                        Button {
                            connect(to: peer)
                        } label: {
                            HStack(spacing: 10) {
                                Image(systemName: "laptopcomputer")
                                    .foregroundStyle(.secondary)
                                    .frame(width: 20)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(peer.name)
                                        .font(.body.weight(.medium))
                                    Text(peer.detail)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                Spacer(minLength: 8)
                                if connectingID == peer.id {
                                    ProgressView()
                                        .controlSize(.small)
                                } else {
                                    Text("Connect")
                                        .font(.callout.weight(.semibold))
                                        .foregroundStyle(.tint)
                                }
                            }
                            .padding(.horizontal, 12)
                            .padding(.vertical, 10)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .disabled(connectingID != nil)
                        if peer.id != nearby.last?.id {
                            Divider().padding(.leading, 42)
                        }
                    }
                }
                .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 8))
            }
        }
    }

    private var pairedSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Paired peers")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .textCase(.uppercase)
            ForEach(model.peers) { peer in
                Button {
                    model.selectedPeerID = peer.id
                    model.phase = .browsingOffers
                    model.refreshPeerOffers()
                } label: {
                    Label(peer.displayName, systemImage: "laptopcomputer")
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .buttonStyle(.bordered)
            }
        }
    }

    private func startBrowsingIfNeeded() {
        model.bonjour.stop()
        nearby = []
        guard nearbyAllowed else { return }
        model.bonjour.start { peers in
            nearby = peers
        }
    }

    private func connect(to peer: BonjourPeer) {
        connectingID = peer.id
        errorText = nil
        Task {
            do {
                try await model.connectAndBrowse(bonjour: peer)
            } catch {
                await MainActor.run {
                    errorText = error.localizedDescription
                    connectingID = nil
                }
            }
        }
    }

    private func symbol(for name: String) -> String {
        switch name {
        case "Documents": return "doc.fill"
        case "Desktop": return "desktopcomputer"
        case "Downloads": return "arrow.down.circle.fill"
        case "Pictures": return "photo.fill"
        case "Movies": return "film.fill"
        case "Music": return "music.note"
        case "Public": return "folder.fill.badge.person.crop"
        default: return "folder.fill"
        }
    }
}
