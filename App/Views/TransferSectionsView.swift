import SwiftUI

/// Transfer job sections: Home Folder tree + stub sections for later.
struct TransferSectionsView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        List {
            Section {
                HomeFolderTree()
            } header: {
                Text("Home Folder")
            } footer: {
                Text("Select folders under your home directory. Documents, Desktop, and Downloads are highlighted as common choices.")
            }

            Section("Services") {
                comingSoonRow("Mail, Safari, and other apps", systemImage: "app.dashed")
            }
            Section("Dock") {
                comingSoonRow("Dock layout and items", systemImage: "dock.rectangle")
            }
            Section("Finder") {
                comingSoonRow("Finder preferences", systemImage: "folder")
            }

            if !model.folderBookmarks.isEmpty {
                Section("Selected for this job") {
                    ForEach(model.folderBookmarks) { folder in
                        HStack {
                            Label(folder.displayName, systemImage: "folder.fill")
                            Spacer()
                            Text(folder.path)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                        .contextMenu {
                            Button("Re-authorize…") { model.reauthorizeFolder(folder.id) }
                            Button("Remove", role: .destructive) { model.removeFolder(folder.id) }
                        }
                    }
                }
            }
        }
    }

    private func comingSoonRow(_ title: String, systemImage: String) -> some View {
        HStack {
            Label(title, systemImage: systemImage)
            Spacer()
            Text("Coming soon")
                .font(.caption)
                .foregroundStyle(.secondary)
            Image(systemName: "circle")
                .foregroundStyle(.tertiary)
        }
        .foregroundStyle(.secondary)
        .disabled(true)
    }
}

private struct HomeFolderTree: View {
    @EnvironmentObject private var model: AppModel
    @State private var roots: [HomeFolderNode] = HomeFolderNode.topLevel()

    var body: some View {
        ForEach(roots) { node in
            HomeFolderRow(node: node)
        }
        Button {
            model.addFolder()
        } label: {
            Label("Choose other folder…", systemImage: "folder.badge.plus")
        }
    }
}

private struct HomeFolderRow: View {
    @EnvironmentObject private var model: AppModel
    let node: HomeFolderNode
    @State private var children: [HomeFolderNode]?
    @State private var expanded = false

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Toggle(isOn: Binding(
                get: { model.isFolderSelected(path: node.url.path) },
                set: { model.setFolderSelected($0, url: node.url) }
            )) {
                EmptyView()
            }
            .toggleStyle(.checkbox)
            .labelsHidden()

            DisclosureGroup(isExpanded: $expanded) {
                if let children {
                    ForEach(children) { child in
                        HomeFolderRow(node: child)
                    }
                }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "folder")
                        .foregroundStyle(node.isConvenience ? Color.accentColor : .secondary)
                    Text(node.name)
                        .fontWeight(node.isConvenience ? .semibold : .regular)
                    if node.isConvenience {
                        Text("Common")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .onChange(of: expanded) { _, isOpen in
            if isOpen, children == nil {
                children = HomeFolderNode.children(of: node.url)
            }
        }
    }
}

struct HomeFolderNode: Identifiable, Hashable {
    var id: String { url.path }
    var url: URL
    var name: String
    var isConvenience: Bool

    private static let convenienceNames: Set<String> = [
        ConvenienceTarget.documents.title,
        ConvenienceTarget.desktop.title,
        ConvenienceTarget.downloads.title,
    ]

    static func topLevel() -> [HomeFolderNode] {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let listed = children(of: home)
        if !listed.isEmpty { return listed }
        // Sandbox fallback: still show common home targets.
        return ConvenienceTarget.allCases.compactMap { target in
            guard let url = target.url else { return nil }
            return HomeFolderNode(url: url, name: target.title, isConvenience: true)
        }
    }

    static func children(of parent: URL) -> [HomeFolderNode] {
        let fm = FileManager.default
        guard let urls = try? fm.contentsOfDirectory(
            at: parent,
            includingPropertiesForKeys: [.isDirectoryKey, .isHiddenKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }

        return urls.compactMap { url -> HomeFolderNode? in
            let values = try? url.resourceValues(forKeys: [.isDirectoryKey])
            guard values?.isDirectory == true else { return nil }
            let name = url.lastPathComponent
            return HomeFolderNode(
                url: url,
                name: name,
                isConvenience: convenienceNames.contains(name)
            )
        }
        .sorted { a, b in
            if a.isConvenience != b.isConvenience { return a.isConvenience && !b.isConvenience }
            return a.name.localizedCaseInsensitiveCompare(b.name) == .orderedAscending
        }
    }
}
