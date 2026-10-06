import SwiftUI
import WatariCore

struct SettingsView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        TabView {
            Tab("General", systemImage: "gearshape") {
                Form {
                    Text("Watari copies chosen folders only. It does not migrate accounts, apps, or MDM profiles.")
                        .foregroundStyle(.secondary)
                    Section("Receive (this Mac is the destination)") {
                        Text("By default, under-home folders map into the same place under your home (Desktop → Desktop). Custom Add folder paths outside the source home keep their absolute path. Ownership remaps to you.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        if let receive = model.receiveFolder {
                            Text("Advanced override: \(receive.path)")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(2)
                            Button("Clear override (use home mapping)") { model.clearReceiveFolderOverride() }
                        }
                        DisclosureGroup("Advanced receive folder…") {
                            Button("Choose parent folder…") { model.chooseReceiveFolder() }
                            Text("Optional single parent; offered roots become subfolders there.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    Section("Offer (this Mac is the source)") {
                        Toggle("Listen for peers", isOn: $model.network.listenEnabled)
                            .onChange(of: model.network.listenEnabled) { _, _ in model.refreshListener() }
                        TextField(
                            "Port",
                            value: $model.network.listenPort,
                            format: IntegerFormatStyle<Int>().grouping(.never)
                        )
                        .onChange(of: model.network.listenPort) { _, _ in model.refreshListener() }
                        Text("Offer catalog and Add folder… live on the main window when Listen is on. Settings keeps Listen/port and the same list for power users. First inbound Connect may show a Firewall dialog — allow Watari once.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        ForEach(model.offeredFolders) { folder in
                            HStack {
                                Text(folder.displayName)
                                Spacer()
                                Text(folder.path)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                            }
                            .contextMenu {
                                Button("Re-authorize…") { model.reauthorizeFolder(folder.id) }
                                Button("Remove", role: .destructive) { model.removeOfferedFolder(folder.id) }
                            }
                        }
                        Button("Add folder…") { model.addOfferedFolder() }
                        Button("Reindex offered folders") {
                            model.reindexOfferedFolders()
                            model.refreshListener()
                        }
                    }
                    DisclosureGroup("Advanced") {
                        NetworkAdvancedForm()
                            .environmentObject(model)
                    }
                }
                .formStyle(.grouped)
                .frame(width: 460)
            }
            Tab("Permissions", systemImage: "person.badge.key") {
                Form {
                    Section("Conflict strategy") {
                        Picker("When hashes differ", selection: $model.conflict) {
                            Text("Keep both").tag(ConflictPolicy.keepBoth)
                            Text("Update").tag(ConflictPolicy.update)
                            Text("Skip").tag(ConflictPolicy.skip)
                        }
                        Text("Chosen at job start. Default is Keep both.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Section("Ownership") {
                        Toggle("Remap owner to receiving user", isOn: $model.policy.remapOwnerToReceivingUser)
                        Toggle("Strip quarantine", isOn: $model.policy.stripQuarantine)
                        Toggle("Keep ACLs when valid", isOn: $model.policy.keepACLs)
                    }
                    .disabled(ManagedDefaults.lockPermissionPolicy)
                    DisclosureGroup("Advanced") {
                        Toggle("Keep mode bits", isOn: $model.policy.keepMode)
                        Toggle("Keep other xattrs", isOn: $model.policy.keepExtendedAttributes)
                        Toggle("Keep Finder flags", isOn: $model.policy.keepFinderFlags)
                        Button("Export exception log…") { model.exportExceptionLog() }
                            .disabled(model.previewSummary == nil && model.jobLog.events.isEmpty)
                    }
                    .disabled(ManagedDefaults.lockPermissionPolicy)
                }
                .formStyle(.grouped)
                .frame(width: 420)
            }
            Tab("Exclusions", systemImage: "eye.slash") {
                Form {
                    Text("Always skipped: keychains, TCC database, configuration profiles.")
                        .foregroundStyle(.secondary)
                    Text("Symlinks are copied as links and never followed outside the selection.")
                        .foregroundStyle(.secondary)
                }
                .formStyle(.grouped)
                .frame(width: 420)
            }
            Tab("DLP", systemImage: "lock.shield") {
                Form {
                    LabeledContent("Status") {
                        Text(model.dlp.enabled ? "Managed policy active" : "Off")
                    }
                    if let label = model.dlp.policyLabel {
                        LabeledContent("Policy label", value: label)
                    }
                    if model.dlp.enabled {
                        LabeledContent("Blocked extensions", value: model.dlp.blockedExtensions.joined(separator: ", "))
                        LabeledContent("Max file bytes", value: model.dlp.maxFileBytes == 0 ? "Unlimited" : "\(model.dlp.maxFileBytes)")
                        Toggle("Block outbound", isOn: .constant(model.dlp.blockOutbound))
                            .disabled(true)
                        Toggle("Block inbound", isOn: .constant(model.dlp.blockInbound))
                            .disabled(true)
                    }
                    Text("DLP is configured via MDM (`app.watari.mac`). Full transfer gates ship in a later release; matching files are skipped during Start when enabled.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .formStyle(.grouped)
                .frame(width: 460)
            }
        }
        .scenePadding()
    }
}

private struct NetworkAdvancedForm: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        Group {
            Picker("Bind", selection: $model.network.bindMode) {
                Text("Localhost").tag(BindMode.localhost)
                Text("LAN interfaces").tag(BindMode.lan)
                Text("Specific address").tag(BindMode.address)
            }
            if model.network.bindMode == .address {
                TextField("Address", text: Binding(
                    get: { model.network.bindAddress ?? "" },
                    set: { model.network.bindAddress = $0 }
                ))
            }
            Picker("Discovery", selection: $model.network.discoveryMode) {
                Text("Off").tag(DiscoveryMode.off)
                Text("Nearby (Bonjour)").tag(DiscoveryMode.nearby)
                Text("Explicit only").tag(DiscoveryMode.explicit)
            }
            .disabled(ManagedDefaults.denyBonjour)
            TextField(
                "Bandwidth limit (bytes/s, 0 = none)",
                value: $model.network.bandwidthLimitBytesPerSecond,
                format: IntegerFormatStyle<UInt64>().grouping(.never)
            )
            TextField(
                "Idle timeout (seconds)",
                value: $model.network.idleTimeoutSeconds,
                format: IntegerFormatStyle<Int>().grouping(.never)
            )
            TextField(
                "Max concurrent transfers",
                value: $model.network.maxConcurrentTransfers,
                format: IntegerFormatStyle<Int>().grouping(.never)
            )
            if ManagedDefaults.managedMode {
                Text("Managed by organization — some values may be locked via \(ManagedPreferenceKey.domain).")
                    .foregroundStyle(.secondary)
            }
            Section("Peers") {
                ForEach(model.peers) { peer in
                    HStack {
                        VStack(alignment: .leading) {
                            Text(peer.displayName)
                            Text(peer.host.map { "\($0):\(peer.port ?? model.network.listenPort)" } ?? "No host")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button("Revoke", role: .destructive) {
                            model.peers.removeAll { $0.id == peer.id }
                            if model.selectedPeerID == peer.id {
                                model.selectedPeerID = nil
                            }
                        }
                    }
                }
            }
        }
    }
}
