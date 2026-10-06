import SwiftUI
import WatariCore

struct ConnectSheet: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss

    @State private var tab: Tab = .explicit
    @State private var host = ""
    @State private var port = "59234"
    @State private var displayName = ""
    @State private var pairingCode = ""
    @State private var nearby: [BonjourPeer] = []
    @State private var busy = false
    @State private var errorText: String?

    enum Tab: String, CaseIterable {
        case explicit = "Host"
        case nearby = "Nearby"
    }

    private var nearbyAllowed: Bool {
        model.network.discoveryMode == .nearby && !ManagedDefaults.denyBonjour
    }

    var body: some View {
        VStack(spacing: 0) {
            Text("Connect peer")
                .font(.title2.weight(.semibold))
                .padding()
            if nearbyAllowed {
                Picker("Method", selection: $tab) {
                    ForEach(Tab.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .padding(.horizontal)
            }
            Group {
                switch tab {
                case .explicit:
                    explicitForm
                case .nearby:
                    nearbyList
                }
            }
            .padding()
            if let errorText {
                Text(errorText)
                    .foregroundStyle(.red)
                    .padding(.horizontal)
            }
            HStack {
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Spacer()
                Button("Pair") { pair() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(busy || (tab == .explicit && host.isEmpty))
            }
            .padding()
        }
        .onAppear {
            if !nearbyAllowed { tab = .explicit }
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
            Text("Primary path for enterprise networks. TLS pins the peer key after pairing.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .formStyle(.grouped)
    }

    private var nearbyList: some View {
        List(nearby) { peer in
            Button {
                host = peer.host
                port = String(peer.port)
                displayName = peer.name
            } label: {
                Label(peer.name, systemImage: "dot.radiowaves.left.and.right")
            }
        }
        .overlay {
            if nearby.isEmpty {
                Text("No Nearby Macs on this segment")
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func pair() {
        busy = true
        errorText = nil
        Task {
            do {
                let portValue = Int(port) ?? model.network.listenPort
                let name = displayName.isEmpty ? host : displayName
                let record = try await model.peerConnector.pair(
                    host: host,
                    port: portValue,
                    displayName: name,
                    pairingCode: pairingCode
                )
                await MainActor.run {
                    model.peers.append(record)
                    model.selectedPeerID = record.id
                    model.showConnectSheet = false
                    if model.folderBookmarks.isEmpty {
                        model.phase = .noFolders
                        model.statusMessage = "Peer saved. Select folders to begin."
                    } else {
                        model.phase = .waitingForPeer
                        model.statusMessage = "Peer paired. Run Preview."
                    }
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
