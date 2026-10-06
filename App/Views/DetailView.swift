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
        .navigationTitle("Crossing")
    }

    private var header: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 4) {
                Text(model.statusMessage)
                    .font(.headline)
                if let warning = model.libraryWarning {
                    Text(warning)
                        .font(.callout)
                        .foregroundStyle(.orange)
                }
            }
            Spacer()
            Menu("Add") {
                ForEach(ConvenienceTarget.allCases) { target in
                    Button(target.title) { model.addConvenience(target) }
                }
                Divider()
                Button("Add Folder…") { model.addFolder() }
            }
            .keyboardShortcut("o", modifiers: [.command])
        }
        .padding()
    }

    @ViewBuilder
    private var content: some View {
        switch model.phase {
        case .noFolders:
            EmptyStateView(
                title: "No folders yet",
                systemImage: "folder.badge.plus",
                message: "Watari copies only the folders you choose. It will not migrate accounts, apps, keychains, or configuration profiles.",
                actionTitle: "Add Folder…",
                action: { model.addFolder() }
            )
        case .waitingForPeer where model.selectedPeerID == nil:
            EmptyStateView(
                title: "Waiting for peer",
                systemImage: "link.badge.plus",
                message: "Connect by hostname or IP. Nearby Bonjour is optional and often blocked on enterprise networks.",
                actionTitle: "Connect…",
                action: { model.showConnectSheet = true }
            )
        case .waitingForPeer:
            folderList
        case .previewReady, .finishedWithExceptions:
            previewList
        case .copying:
            VStack(spacing: 16) {
                ProgressView(value: model.progressFraction)
                    .progressViewStyle(.linear)
                    .padding(.horizontal)
                Text(model.statusMessage)
                    .foregroundStyle(.secondary)
                folderList
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

    private var folderList: some View {
        List {
            Section("Sources") {
                ForEach(ConvenienceTarget.allCases) { target in
                    Button {
                        model.addConvenience(target)
                    } label: {
                        Label(target.title, systemImage: "folder")
                    }
                }
                Button {
                    model.addFolder()
                } label: {
                    Label("Add Folder…", systemImage: "folder.badge.plus")
                }
            }
            Section("Folders in this job") {
                if model.folderBookmarks.isEmpty {
                    Text("None yet")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(model.folderBookmarks) { folder in
                        HStack {
                            Label(folder.displayName, systemImage: "folder")
                            Spacer()
                            Text(folder.path)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                        .contextMenu {
                            Button("Remove", role: .destructive) { model.removeFolder(folder.id) }
                        }
                    }
                }
            }
        }
    }

    private var previewList: some View {
        List {
            if let preview = model.preview {
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
                                } else if let owner = item.source?.ownerName {
                                    Text("owner \(owner)")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                            Spacer()
                            Text(item.action.rawValue)
                                .foregroundStyle(.secondary)
                        }
                        .accessibilityElement(children: .combine)
                        .accessibilityLabel("\(item.relativePath), \(item.action.rawValue)")
                    }
                }
            }
            folderList
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
