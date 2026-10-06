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

    var body: some View {
        ScrollView {
            VStack(spacing: 0) {
                Text("Choose what to transfer")
                    .font(.title2.weight(.semibold))
                    .multilineTextAlignment(.center)
                    .padding(.top, 28)

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

                // Folders — files only (whitelist + Add folder…)
                VStack(alignment: .leading, spacing: 8) {
                    HStack(alignment: .firstTextBaseline) {
                        Text("Folders")
                            .font(.headline)
                        Spacer()
                        Button("Add folder…") {
                            model.addFolder()
                        }
                        .help("Choose another folder (opens a system folder picker)")
                    }

                    borderedFolderTree
                        .frame(minHeight: 220, maxHeight: 320)

                    footer
                }
                .frame(maxWidth: 540, alignment: .leading)
                .padding(.top, 20)
                .padding(.horizontal, 40)

                // Separate transfer section — not part of the file tree
                VStack(alignment: .leading, spacing: 8) {
                    Text("Services")
                        .font(.headline)
                    Text("App data and settings. Coming later — not part of the folder transfer.")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    borderedServicesList
                }
                .frame(maxWidth: 540, alignment: .leading)
                .padding(.top, 22)
                .padding(.horizontal, 40)

                phaseChrome
                    .padding(.top, 16)
                    .padding(.horizontal, 40)
                    .padding(.bottom, 28)
            }
            .frame(maxWidth: .infinity)
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
            return "Select folders to copy to another Mac."
        }
    }

    private var borderedFolderTree: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                TransferTreeRow(
                    title: "Users",
                    systemImage: "person.2.fill",
                    trailing: sizeLabel(for: homeURL.path),
                    depth: 0,
                    isExpanded: $sizes.usersExpanded,
                    canExpand: true,
                    selection: usersSelection,
                    enabled: true,
                    onToggle: { selectAllWhitelistedFolders($0) }
                )

                if sizes.usersExpanded {
                    TransferTreeRow(
                        title: userName,
                        systemImage: "person.crop.circle.fill",
                        trailing: sizeLabel(for: homeURL.path),
                        depth: 1,
                        isExpanded: $sizes.userExpanded,
                        canExpand: true,
                        selection: usersSelection,
                        enabled: true,
                        onToggle: { selectAllWhitelistedFolders($0) }
                    )

                    if sizes.userExpanded {
                        ForEach(folderNodes) { node in
                            folderRow(node)
                        }

                        // Extra folders added via Add folder… that aren’t in the whitelist tree.
                        ForEach(extraSelectedFolders) { entry in
                            TransferTreeRow(
                                title: entry.displayName,
                                systemImage: "folder.fill",
                                trailing: sizeLabel(for: entry.path),
                                depth: 2,
                                isExpanded: .constant(false),
                                canExpand: false,
                                selection: .on,
                                enabled: true,
                                onToggle: { selected in
                                    if !selected { model.removeFolder(entry.id) }
                                }
                            )
                            .contextMenu {
                                Button("Re-authorize…") { model.reauthorizeFolder(entry.id) }
                                Button("Remove", role: .destructive) { model.removeFolder(entry.id) }
                            }
                            .onAppear { sizes.estimate(paths: [entry.path]) }
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

    /// Bookmarks outside the default whitelist (from Add folder…).
    private var extraSelectedFolders: [BookmarkEntry] {
        let whitelistPaths = Set(folderNodes.map(\.url.path))
        return model.folderBookmarks.filter { !whitelistPaths.contains($0.path) }
    }

    private var borderedServicesList: some View {
        VStack(alignment: .leading, spacing: 0) {
            comingSoonRow(
                title: "Services",
                systemImage: "app.dashed",
                detail: "Mail, Safari, and other apps"
            )
            Divider().padding(.leading, 44)
            comingSoonRow(
                title: "Dock",
                systemImage: "dock.rectangle",
                detail: "Dock layout and items"
            )
            Divider().padding(.leading, 44)
            comingSoonRow(
                title: "Finder",
                systemImage: "folder",
                detail: "Finder preferences"
            )
        }
        .padding(.vertical, 4)
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
            trailing: sizeLabel(for: path),
            depth: 2,
            isExpanded: .constant(false),
            canExpand: false,
            selection: selected ? .on : .off,
            enabled: true,
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

    private func comingSoonRow(
        title: String,
        systemImage: String,
        detail: String
    ) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "square")
                .font(.body)
                .foregroundStyle(Color(nsColor: .tertiaryLabelColor))
                .frame(width: 16, height: 16)
            Image(systemName: systemImage)
                .foregroundStyle(.tertiary)
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .foregroundStyle(.secondary)
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
            Spacer(minLength: 8)
            Text("Coming soon")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .opacity(0.85)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(title), coming soon")
    }

    private var footer: some View {
        let selected: String = {
            let unknownSizes = model.folderBookmarks.contains { sizes.bytes(for: $0.path) == nil }
            if !model.folderBookmarks.isEmpty, selectedBytes == 0, unknownSizes {
                let n = model.folderBookmarks.count
                return n == 1 ? "1 folder" : "\(n) folders"
            }
            return ByteCountFormatter.string(fromByteCount: Int64(selectedBytes), countStyle: .file)
        }()
        let available: String = {
            if let availableBytes {
                return ByteCountFormatter.string(fromByteCount: Int64(availableBytes), countStyle: .file)
            }
            return "—"
        }()
        let dest = model.selectedPeer?.displayName ?? "this Mac"
        return Text("\(selected) selected to transfer. \(available) available on \(dest).")
            .font(.caption)
            .foregroundStyle(.secondary)
            .accessibilityLabel("\(selected) selected to transfer. \(available) available on \(dest).")
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

    private func selectAllWhitelistedFolders(_ selected: Bool) {
        model.setFoldersSelected(selected, urls: folderNodes.map(\.url))
    }

    private func sizeLabel(for path: String) -> String {
        guard let bytes = sizes.bytes(for: path) else { return "—" }
        return ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
    }
}

// MARK: - Row

private enum RowSelection {
    case on, off, mixed
}

private struct TransferTreeRow: View {
    var title: String
    var systemImage: String
    var trailing: String
    var depth: Int
    @Binding var isExpanded: Bool
    var canExpand: Bool
    var selection: RowSelection
    var enabled: Bool
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

            Image(systemName: checkboxSymbol)
                .font(.body)
                .foregroundStyle(checkboxColor)
                .frame(width: 16, height: 16)
                .accessibilityHidden(true)

            Image(systemName: systemImage)
                .foregroundStyle(enabled ? .secondary : .tertiary)
                .frame(width: 18)

            Text(title)
                .foregroundStyle(enabled ? Color.primary : Color.secondary)
                .lineLimit(1)

            Spacer(minLength: 8)

            Text(trailing)
                .font(.caption)
                .foregroundStyle(.secondary)
                .monospacedDigit()
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 4)
        .contentShape(Rectangle())
        .opacity(enabled ? 1 : 0.75)
        .onTapGesture {
            guard enabled else { return }
            switch selection {
            case .on: onToggle(false)
            case .off, .mixed: onToggle(true)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(title)
        .accessibilityValue(accessibilityValue)
        .accessibilityAddTraits(enabled ? .isButton : [])
        .accessibilityAction {
            guard enabled else { return }
            switch selection {
            case .on: onToggle(false)
            case .off, .mixed: onToggle(true)
            }
        }
    }

    private var checkboxSymbol: String {
        switch selection {
        case .on: return "checkmark.square.fill"
        case .mixed: return "minus.square.fill"
        case .off: return "square"
        }
    }

    private var checkboxColor: Color {
        if !enabled { return Color(nsColor: .tertiaryLabelColor) }
        return selection == .off ? Color.secondary : Color.accentColor
    }

    private var accessibilityValue: String {
        if !enabled { return "coming soon" }
        switch selection {
        case .on: return "selected"
        case .mixed: return "partially selected"
        case .off: return "not selected"
        }
    }
}

// MARK: - Model

struct TransferNode: Identifiable, Hashable {
    var id: String { url.path }
    var url: URL
    var name: String
    var systemImage: String

    /// User-facing folders only — never Library, SystemData, tmp, or other junk.
    static let allowedNames = Array(BookmarkStore.whitelistedHomeFolderNames).sorted { a, b in
        let order = ["Desktop", "Documents", "Downloads", "Pictures", "Movies", "Music", "Public"]
        let ai = order.firstIndex(of: a) ?? Int.max
        let bi = order.firstIndex(of: b) ?? Int.max
        if ai != bi { return ai < bi }
        return a.localizedCaseInsensitiveCompare(b) == .orderedAscending
    }

    static func homeFolders(of home: URL) -> [TransferNode] {
        let fm = FileManager.default
        return allowedNames.compactMap { name -> TransferNode? in
            let url = home.appendingPathComponent(name, isDirectory: true).standardizedFileURL
            var isDir: ObjCBool = false
            // Only list folders that exist; missing dirs caused spurious selection errors.
            guard fm.fileExists(atPath: url.path, isDirectory: &isDir), isDir.boolValue else {
                return nil
            }
            return TransferNode(url: url, name: name, systemImage: symbol(for: name))
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
