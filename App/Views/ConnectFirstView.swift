import SwiftUI
import WatariCore

/// Destination-primary first screen — connect before any folder checklist.
struct ConnectFirstView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        VStack(spacing: 0) {
            Spacer(minLength: 32)
            Text("Connect to a Mac")
                .font(.title2.weight(.semibold))
            Text("Watari pulls folders from another Mac that is offering them. Connect first, then choose what to transfer.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 420)
                .padding(.top, 8)
                .padding(.horizontal, 32)

            VStack(spacing: 12) {
                Button {
                    model.showConnectSheet = true
                } label: {
                    Label("Connect…", systemImage: "link")
                        .frame(maxWidth: 280)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .keyboardShortcut(.defaultAction)

                if !model.peers.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Paired peers")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        ForEach(model.peers) { peer in
                            Button {
                                model.selectedPeerID = peer.id
                                model.phase = .browsingOffers
                                model.refreshPeerOffers()
                            } label: {
                                Label(peer.displayName, systemImage: "laptopcomputer")
                                    .frame(maxWidth: 280, alignment: .leading)
                            }
                            .buttonStyle(.bordered)
                        }
                    }
                    .padding(.top, 8)
                }
            }
            .padding(.top, 28)

            Text("On the other Mac: enable Listen in Settings and keep Watari open so it can offer folders.")
                .font(.caption)
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 400)
                .padding(.top, 24)
                .padding(.horizontal, 32)

            Spacer(minLength: 32)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
