import SwiftUI
import WatariCore

/// Destination-first screen — Connect / Nearby. Offering is a secondary path.
struct ConnectFirstView: View {
    @EnvironmentObject private var model: AppModel

    @State private var nearby: [BonjourPeer] = []
    @State private var connectingID: String?
    @State private var errorText: String?

    private var nearbyAllowed: Bool { model.nearbyDiscoveryAllowed }

    var body: some View {
        ScrollView {
            VStack(spacing: 0) {
                Text("Connect to a Mac")
                    .font(.title2.weight(.semibold))
                    .padding(.top, 28)

                Text("Watari pulls folders from another Mac that is offering them. Choose a Nearby Mac, or connect by host.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 420)
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

                VStack(alignment: .leading, spacing: 12) {
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
                .frame(maxWidth: 360, alignment: .leading)
                .padding(.top, 24)
                .padding(.horizontal, 40)

                Text(footerHint)
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 400)
                    .padding(.top, 20)
                    .padding(.horizontal, 32)

                // Secondary: become a source without cluttering the pull flow.
                Button {
                    model.network.listenEnabled = true
                    model.refreshListener()
                    model.showSourcePrep = true
                } label: {
                    Label("Offer folders from this Mac…", systemImage: "folder.badge.plus")
                }
                .buttonStyle(.borderless)
                .padding(.top, 28)
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
    }

    private var footerHint: String {
        if nearbyAllowed {
            return "On the other Mac: Listen on, offer folders, leave Watari open."
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
}
