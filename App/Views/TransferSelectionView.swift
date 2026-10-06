import AppKit
import SwiftUI

/// Migration Assistant–style transfer picker: title, one bordered tree, footer summary.
struct TransferSelectionView: View {
    @EnvironmentObject private var model: AppModel
    @StateObject private var sizes = FolderSizeStore()

    private var userName: String {
        let full = NSFullUserName()
        return full.isEmpty ? NSUserName() : full
    }

    private var homeURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
    }

    private var folderNodes: [TransferNode] {
        TransferNode.homeFolders(of: homeURL)
    }

    private var selectedBytes: UInt64 {
        model.folderBookmarks.reduce(UInt64(0)) { partial, entry in
            partial + (sizes.bytes(for: entry.path) ?? 0)
        }
    }

    private var availableBytes: UInt64? {
        sizes.volumeFreeBytes
    }

    private var destinationLabel: String {
        if let peer = model.selectedPeer {
            return peer.displayName
        }
        return "this Mac"
    }

    var body: some View {
        VStack(spacing: 0) {
            Spacer(minLength: 28)

            Text("Choose what to transfer")
                .font(.title2.weight(.semibold))
                .multilineTextAlignment(.center)

            Text(subtitle)
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.top, 6)
                .padding(.horizontal, 32)

            if let warning = model.libraryWarning {
                Text(warning)
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .multilineTextAlignment(.center)
                    .padding(.top, 8)
                    .padding(.horizontal, 32)
            }

            borderedTree
                .frame(maxWidth: 540)
                .frame(minHeight: 240, maxHeight: 360)
                .padding(.top, 20)
                .padding(.horizontal, 40)

            footer
                .frame(maxWidth: 540, alignment: .leading)
                .padding(.top, 10)
                .padding(.horizontal, 40)

            phaseChrome
                .padding(.top, 16)
                .padding(.horizontal, 40)

            Spacer(minLength: 28)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear {
            sizes.refreshVolumeFree()
            sizes.estimate(paths: folderNodes.map(\.url.path))
        }
    }

    private var subtitle: String {
        switch model.phase {
        case .previewReady, .finishedWithExceptions:
            return model.statusMessage
        case .copying:
            return "Copying selected folders…"
        case .peerGone:
            return "The other Mac disconnected. Reconnect, then Preview again."
        case .waitingForPeer:
            return model.selectedPeerID == nil
                ? "Select folders, then connect a peer."
                : "Select folders, then Preview what will copy."
        case .noFolders:
            return "Select folders from your home directory to copy to another Mac."
        }
    }

    private var borderedTree: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                TransferTreeRow(
                    title: "Users",
                    systemImage: "person.2.fill",
                    bytes: sizes.bytes(for: homeURL.path),
                    depth: 0,
                    isExpanded: $sizes.usersExpanded,
                    canExpand: true,
                    selection: usersSelection,
                    onToggle: { selectAllHomeFolders($0) }
                )

                if sizes.usersExpanded {
                    TransferTreeRow(
                        title: userName,
                        systemImage: "person.crop.circle.fill",
                        bytes: sizes.bytes(for: homeURL.path),
                        depth: 1,
                        isExpanded: $sizes.userExpanded,
                        canExpand: true,
                        selection: usersSelection,
                        onToggle: { selectAllHomeFolders($0) }
                    )

                    if sizes.userExpanded {
                        ForEach(folderNodes) { node in
                            folderRow(node)
                        }
                    }
                }
            }
            .padding(.vertical, 6)
        }
        .background(Color(nsColor: .textBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .strokeBorder(Color(nsColor: .separatorColor), lineWidth: 1)
        )
    }

    private func folderRow(_ node: TransferNode) -> some View {
        let path = node.url.path
        let selected = model.isFolderSelected(path: path)
        return TransferTreeRow(
            title: node.name,
            systemImage: node.systemImage,
            bytes: sizes.bytes(for: path),
            depth: 2,
            isExpanded: .constant(false),
            canExpand: false,
            selection: selected ? .on : .off,
            onToggle: { model.setFolderSelected($0, url: node.url) }
        )
        .contextMenu {
            if selected, let entry = model.folderBookmarks.first(where: { $0.path == path }) {
                Button("Re-authorize…") { model.reauthorizeFolder(entry.id) }
                Button("Remove", role: .destructive) { model.removeFolder(entry.id) }
            }
        }
        .onAppear { sizes.estimate(paths: [path]) }
    }

    private var footer: some View {
        let selected = ByteCountFormatter.string(fromByteCount: Int64(selectedBytes), countStyle: .file)
        let available: String = {
            if let availableBytes {
                return ByteCountFormatter.string(fromByteCount: Int64(availableBytes), countStyle: .file)
            }
            return "—"
        }()
        return Text("\(selected) selected to transfer. \(available) available on \(destinationLabel).")
            .font(.caption)
            .foregroundStyle(.secondary)
            .accessibilityLabel("\(selected) selected to transfer. \(available) available on \(destinationLabel).")
    }

    @ViewBuilder
    private var phaseChrome: some View {
        switch model.phase {
        case .copying:
            ProgressView(value: model.progressFraction)
                .progressViewStyle(.linear)
                .frame(maxWidth: 540)
        case .previewReady, .finishedWithExceptions:
            if let preview = model.previewSummary {
                Text(
                    "Preview: \(preview.copy) copy · \(preview.update) update · \(preview.unchanged) unchanged · \(preview.skip) skip"
                )
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(maxWidth: 540, alignment: .leading)
            }
        case .peerGone:
            Button("Connect…") { model.showConnectSheet = true }
                .keyboardShortcut(.defaultAction)
        default:
            EmptyView()
        }
    }

    private var usersSelection: RowSelection {
        let nodes = folderNodes
        guard !nodes.isEmpty else { return .off }
        let selectedCount = nodes.filter { model.isFolderSelected(path: $0.url.path) }.count
        if selectedCount == 0 { return .off }
        if selectedCount == nodes.count { return .on }
        return .mixed
    }

    private func selectAllHomeFolders(_ selected: Bool) {
        if selected {
            // Sandbox grants are per-folder — don’t fire a stack of open panels.
            // Selecting the parent means “pick the common set” one at a time for unchecked convenience folders.
            let convenience = ["Documents", "Desktop", "Downloads"]
            for node in folderNodes where convenience.contains(node.name) {
                if !model.isFolderSelected(path: node.url.path) {
                    model.setFolderSelected(true, url: node.url)
                }
            }
        } else {
            for entry in model.folderBookmarks {
                model.removeFolder(entry.id)
            }
        }
    }
}

// MARK: - Row

private enum RowSelection {
    case on, off, mixed
}

private struct TransferTreeRow: View {
    var title: String
    var systemImage: String
    var bytes: UInt64?
    var depth: Int
    @Binding var isExpanded: Bool
    var canExpand: Bool
    var selection: RowSelection
    var onToggle: (Bool) -> Void

    var body: some View {
        HStack(spacing: 6) {
            Color.clear.frame(width: CGFloat(depth) * 16)

            if canExpand {
                Button {
                    withAnimation(.easeInOut(duration: 0.15)) { isExpanded.toggle() }
                } label: {
                    Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .frame(width: 12, height: 12)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(isExpanded ? "Collapse \(title)" : "Expand \(title)")
            } else {
                Color.clear.frame(width: 12, height: 12)
            }

            Button {
                switch selection {
                case .on: onToggle(false)
                case .off, .mixed: onToggle(true)
                }
            } label: {
                Image(systemName: checkboxSymbol)
                    .font(.body)
                    .foregroundStyle(selection == .off ? Color.secondary : Color.accentColor)
                    .frame(width: 16, height: 16)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(title)
            .accessibilityValue(selection == .on ? "selected" : selection == .mixed ? "partially selected" : "not selected")
            .accessibilityAddTraits(.isButton)

            Image(systemName: systemImage)
                .foregroundStyle(.secondary)
                .frame(width: 18)

            Text(title)
                .lineLimit(1)

            Spacer(minLength: 8)

            Text(sizeLabel)
                .font(.caption)
                .foregroundStyle(.secondary)
                .monospacedDigit()
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 4)
        .contentShape(Rectangle())
    }

    private var checkboxSymbol: String {
        switch selection {
        case .on: return "checkmark.square.fill"
        case .mixed: return "minus.square.fill"
        case .off: return "square"
        }
    }

    private var sizeLabel: String {
        guard let bytes else { return "—" }
        return ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
    }
}

// MARK: - Model

struct TransferNode: Identifiable, Hashable {
    var id: String { url.path }
    var url: URL
    var name: String
    var systemImage: String

    /// Top-level home folders. Library is listed but not a deep picker.
    static func homeFolders(of home: URL) -> [TransferNode] {
        let preferred = [
            "Documents", "Desktop", "Downloads", "Pictures", "Movies", "Music", "Public",
        ]
        let fm = FileManager.default
        guard let urls = try? fm.contentsOfDirectory(
            at: home,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else {
            return preferred.compactMap { name in
                let url = home.appendingPathComponent(name, isDirectory: true)
                var isDir: ObjCBool = false
                guard fm.fileExists(atPath: url.path, isDirectory: &isDir), isDir.boolValue else { return nil }
                return TransferNode(url: url, name: name, systemImage: symbol(for: name))
            }
        }

        let directories = urls.compactMap { url -> TransferNode? in
            let values = try? url.resourceValues(forKeys: [.isDirectoryKey])
            guard values?.isDirectory == true else { return nil }
            let name = url.lastPathComponent
            // Skip deep Library browsing; still allow selecting Library as a whole (with warning).
            return TransferNode(url: url, name: name, systemImage: symbol(for: name))
        }

        return directories.sorted { a, b in
            let ai = preferred.firstIndex(of: a.name) ?? Int.max
            let bi = preferred.firstIndex(of: b.name) ?? Int.max
            if ai != bi { return ai < bi }
            return a.name.localizedCaseInsensitiveCompare(b.name) == .orderedAscending
        }
    }

    private static func symbol(for name: String) -> String {
        switch name {
        case "Documents": return "doc.fill"
        case "Desktop": return "desktopcomputer"
        case "Downloads": return "arrow.down.circle.fill"
        case "Pictures": return "photo.fill"
        case "Movies": return "film.fill"
        case "Music": return "music.note"
        case "Public": return "folder.fill.badge.person.crop"
        case "Library": return "books.vertical.fill"
        case "Applications": return "square.grid.2x2.fill"
        default: return "folder.fill"
        }
    }
}

// MARK: - Size cache

@MainActor
final class FolderSizeStore: ObservableObject {
    @Published private(set) var byteCounts: [String: UInt64] = [:]
    @Published private(set) var volumeFreeBytes: UInt64?
    @Published var usersExpanded = true
    @Published var userExpanded = true

    private var inFlight = Set<String>()

    func bytes(for path: String) -> UInt64? {
        byteCounts[path]
    }

    func refreshVolumeFree() {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        if let attrs = try? FileManager.default.attributesOfFileSystem(forPath: home),
           let free = attrs[.systemFreeSize] as? NSNumber {
            volumeFreeBytes = free.uint64Value
        }
    }

    func estimate(paths: [String]) {
        for path in paths where byteCounts[path] == nil && !inFlight.contains(path) {
            inFlight.insert(path)
            let captured = path
            Task.detached(priority: .utility) {
                let total = Self.allocatedSize(of: URL(fileURLWithPath: captured))
                await MainActor.run {
                    self.byteCounts[captured] = total
                    self.inFlight.remove(captured)
                }
            }
        }
    }

    nonisolated private static func allocatedSize(of url: URL) -> UInt64 {
        let fm = FileManager.default
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: url.path, isDirectory: &isDir) else { return 0 }
        if !isDir.boolValue {
            let values = try? url.resourceValues(forKeys: [.totalFileAllocatedSizeKey, .fileSizeKey])
            return UInt64(values?.totalFileAllocatedSize ?? values?.fileSize ?? 0)
        }

        var total: UInt64 = 0
        guard let enumerator = fm.enumerator(
            at: url,
            includingPropertiesForKeys: [.isRegularFileKey, .totalFileAllocatedSizeKey, .fileSizeKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else { return 0 }

        // Cap work so the picker stays responsive in sandbox / large trees.
        var visited = 0
        let limit = 8_000
        while let item = enumerator.nextObject() as? URL {
            visited += 1
            if visited > limit { break }
            let values = try? item.resourceValues(forKeys: [
                .isRegularFileKey, .totalFileAllocatedSizeKey, .fileSizeKey,
            ])
            guard values?.isRegularFile == true else { continue }
            total += UInt64(values?.totalFileAllocatedSize ?? values?.fileSize ?? 0)
        }
        return total
    }
}
