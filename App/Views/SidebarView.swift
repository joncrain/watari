import SwiftUI
import WatariCore

struct SidebarView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        List(selection: $model.selectedPeerID) {
            Section("This Mac") {
                Label(Host.current().localizedName ?? "This Mac", systemImage: "desktopcomputer")
            }
            Section("Paired peers") {
                if model.peers.isEmpty {
                    Text("No peers yet")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(model.peers) { peer in
                        Label(peer.displayName, systemImage: "laptopcomputer")
                            .tag(Optional(peer.id))
                    }
                }
            }
            Section("Jobs") {
                Label("Current", systemImage: "arrow.left.arrow.right")
            }
        }
        .listStyle(.sidebar)
        .navigationTitle("Watari")
        .safeAreaInset(edge: .bottom) {
            Button {
                model.showConnectSheet = true
            } label: {
                Label("Connect peer", systemImage: "plus")
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(.borderless)
            .padding(12)
        }
    }
}
