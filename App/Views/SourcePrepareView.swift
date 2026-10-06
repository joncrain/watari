import SwiftUI
import WatariCore

/// Source Mac: offer catalog + Listen — shown when a peer connects inbound, or via “Offer folders…”.
struct SourcePrepareView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        ScrollView {
            VStack(spacing: 0) {
                Text("Prepare this Mac")
                    .font(.title2.weight(.semibold))
                    .padding(.top, 28)

                Text(subtitle)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 440)
                    .padding(.top, 8)
                    .padding(.horizontal, 32)

                VStack(alignment: .leading, spacing: 10) {
                    HStack(alignment: .firstTextBaseline) {
                        Text("Offer from this Mac")
                            .font(.headline)
                        Spacer()
                        Text(model.isListening
                             ? "Listening on \(model.network.listenPort)"
                             : (model.network.listenEnabled ? "Listen on — starting…" : "Listen off"))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    Toggle("Listen for peers", isOn: $model.network.listenEnabled)
                        .onChange(of: model.network.listenEnabled) { _, _ in
                            model.refreshListener()
                        }

                    if model.inboundPeerConnected {
                        Text("A Mac is connected. Keep Watari open while they choose folders and Start.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else {
                        Text("Peers see this catalog when they Connect. Add folders here — they choose what to pull.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

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
                }
                .frame(maxWidth: 540, alignment: .leading)
                .padding(.top, 22)
                .padding(.horizontal, 40)

                Button {
                    model.showSourcePrep = false
                } label: {
                    Label("Pull from another Mac…", systemImage: "link")
                }
                .buttonStyle(.bordered)
                .padding(.top, 28)
                .padding(.bottom, 32)
            }
            .frame(maxWidth: .infinity)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var subtitle: String {
        if model.inboundPeerConnected {
            return "Another Mac is pulling from you. Confirm the folders below are what you want to offer."
        }
        return "Offer folders for another Mac to pull."
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
                        Image(systemName: "folder.fill")
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
}
