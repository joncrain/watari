import SwiftUI
import WatariCore

/// Connect sheet: Nearby device list first (when allowed); host/port as advanced.
struct ConnectSheet: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss

    @State private var showManual = false
    @State private var host = ""
    @State private var port = "59234"
    @State private var displayName = ""
    @State private var pairingCode = ""
    @State private var nearby: [BonjourPeer] = []
    @State private var connectingID: String?
    @State private var busy = false
    @State private var errorText: String?

    private var nearbyAllowed: Bool { model.nearbyDiscoveryAllowed }

    var body: some View {
        VStack(spacing: 0) {
            Text("Connect peer")
                .font(.title2.weight(.semibold))
                .padding()

            Group {
                if nearbyAllowed {
                    nearbyList
                    DisclosureGroup("Connect by host / port", isExpanded: $showManual) {
                        explicitForm
                    }
                    .padding(.horizontal)
                    .padding(.bottom, 8)
                } else {
                    explicitForm
                        .padding(.horizontal)
                }
            }

            if let errorText {
                Text(errorText)
                    .foregroundStyle(.red)
                    .font(.callout)
                    .padding(.horizontal)
                    .padding(.bottom, 8)
            }

            HStack {
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Spacer()
                if !nearbyAllowed || showManual {
                    Button(busy ? "Connecting…" : "Connect") { pairManual() }
                        .keyboardShortcut(.defaultAction)
                        .disabled(busy || host.isEmpty || connectingID != nil)
                }
            }
            .padding()
        }
        .frame(minWidth: 420, minHeight: nearbyAllowed ? 360 : 280)
        .onAppear {
            if !nearbyAllowed { showManual = true }
            if nearbyAllowed {
                model.bonjour.start { peers in
                    nearby = peers
                }
            }
        }
        .onDisappear { model.bonjour.stop() }
    }

    private var explicitForm: some View {
        Form {
            TextField("Display name", text: $displayName)
            TextField("Hostname or IP", text: $host)
            TextField("Port", text: $port)
            TextField("Pairing code", text: $pairingCode)
                .help("Short code shown on the other Mac")
            Text("Use this on segmented networks where Nearby is blocked. TLS pins the peer key after pairing.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .formStyle(.grouped)
    }

    private var nearbyList: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Nearby Macs")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .textCase(.uppercase)
                .padding(.horizontal)

            List(nearby) { peer in
                Button {
                    connectNearby(peer)
                } label: {
                    HStack {
                        Label(peer.name, systemImage: "laptopcomputer")
                        Spacer()
                        if connectingID == peer.id {
                            ProgressView()
                                .controlSize(.small)
                        } else {
                            Text(peer.detail)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(busy || connectingID != nil)
            }
            .frame(minHeight: 140, maxHeight: 200)
            .overlay {
                if nearby.isEmpty {
                    Text("Looking for Macs on this network…")
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private func connectNearby(_ peer: BonjourPeer) {
        connectingID = peer.id
        errorText = nil
        Task {
            do {
                try await model.connectAndBrowse(bonjour: peer)
                await MainActor.run { dismiss() }
            } catch {
                await MainActor.run {
                    errorText = error.localizedDescription
                    connectingID = nil
                }
            }
        }
    }

    private func pairManual() {
        busy = true
        errorText = nil
        Task {
            do {
                let portValue = Int(port) ?? model.network.listenPort
                try await model.connectAndBrowse(
                    host: host,
                    port: portValue,
                    displayName: displayName.isEmpty ? host : displayName,
                    pairingCode: pairingCode
                )
                await MainActor.run {
                    busy = false
                    dismiss()
                }
            } catch {
                await MainActor.run {
                    errorText = error.localizedDescription
                    busy = false
                }
            }
        }
    }
}
