import SwiftUI
import WatariCore

struct DetailView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            content
        }
        .navigationTitle("Watari")
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(model.statusMessage)
                .font(.headline)
            if let warning = model.libraryWarning {
                Text(warning)
                    .font(.callout)
                    .foregroundStyle(.orange)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
    }

    @ViewBuilder
    private var content: some View {
        switch model.phase {
        case .noFolders, .waitingForPeer:
            TransferSectionsView()
        case .previewReady, .finishedWithExceptions:
            previewList
        case .copying:
            VStack(spacing: 16) {
                ProgressView(value: model.progressFraction)
                    .progressViewStyle(.linear)
                    .padding(.horizontal)
                Text(model.statusMessage)
                    .foregroundStyle(.secondary)
                TransferSectionsView()
            }
        case .peerGone:
            EmptyStateView(
                title: "Peer gone mid-copy",
                systemImage: "wifi.exclamationmark",
                message: "The other Mac disconnected. Reconnect and run Preview again before retrying.",
                actionTitle: "Connect…",
                action: { model.showConnectSheet = true }
            )
        }
    }

    private var previewList: some View {
        List(selection: $model.selectedPreviewPath) {
            if let preview = model.previewSummary {
                Section("Preview") {
                    LabeledContent("Copy", value: "\(preview.copy)")
                    LabeledContent("Update", value: "\(preview.update)")
                    LabeledContent("Keep both", value: "\(preview.keepBoth)")
                    LabeledContent("Unchanged", value: "\(preview.unchanged)")
                    LabeledContent("Skip", value: "\(preview.skip)")
                    LabeledContent("Permission notes", value: "\(preview.permissionExceptionCount)")
                    LabeledContent(
                        "Indexed",
                        value: ByteCountFormatter.string(fromByteCount: Int64(model.indexedBytes), countStyle: .file)
                    )
                    LabeledContent(
                        "Peer inventory",
                        value: model.peerInventoryAvailable ? "Yes" : "Unavailable"
                    )
                }
                Section("Items") {
                    ForEach(preview.items, id: \.relativePath) { item in
                        HStack {
                            Image(systemName: symbol(for: item.action))
                            VStack(alignment: .leading) {
                                Text(item.relativePath)
                                if let reason = item.skipReason {
                                    Text(reason.rawValue)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                } else {
                                    Text("src \(item.source?.ownerName ?? "—") → dst \(item.destination?.ownerName ?? "—")")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                            Spacer()
                            Text(item.action.rawValue)
                                .foregroundStyle(.secondary)
                        }
                        .tag(item.relativePath)
                        .accessibilityElement(children: .combine)
                        .accessibilityLabel("\(item.relativePath), \(item.action.rawValue)")
                    }
                }
            }
            Section("Home Folder") {
                Text("\(model.folderBookmarks.count) folder(s) selected")
                    .foregroundStyle(.secondary)
                ForEach(model.folderBookmarks) { folder in
                    Label(folder.displayName, systemImage: "folder.fill")
                }
            }
        }
    }

    private func symbol(for action: PreviewAction) -> String {
        switch action {
        case .copy: return "plus.circle"
        case .update: return "arrow.triangle.2.circlepath"
        case .keepBoth: return "doc.on.doc"
        case .unchanged: return "checkmark.circle"
        case .skip: return "minus.circle"
        }
    }
}
