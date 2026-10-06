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
                }
                .formStyle(.grouped)
                .frame(width: 420)
            }
            Tab("Network", systemImage: "network") {
                NetworkSettingsForm()
                    .environmentObject(model)
                    .frame(width: 460)
            }
            Tab("Permissions", systemImage: "person.badge.key") {
                Form {
                    Toggle("Remap owner to receiving user", isOn: $model.policy.remapOwnerToReceivingUser)
                    Toggle("Strip quarantine", isOn: $model.policy.stripQuarantine)
                    Toggle("Keep ACLs when valid", isOn: $model.policy.keepACLs)
                }
                .formStyle(.grouped)
                .frame(width: 420)
                .disabled(ManagedDefaults.lockPermissionPolicy)
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
        }
        .scenePadding()
    }
}

struct NetworkSettingsForm: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        Form {
            Section {
                Toggle("Listen for inbound jobs", isOn: $model.network.listenEnabled)
                TextField("Port", value: $model.network.listenPort, format: .number)
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
                TextField("Bandwidth limit (bytes/s, 0 = none)", value: $model.network.bandwidthLimitBytesPerSecond, format: .number)
                TextField("Idle timeout (seconds)", value: $model.network.idleTimeoutSeconds, format: .number)
                TextField("Max concurrent transfers", value: $model.network.maxConcurrentTransfers, format: .number)
            } footer: {
                if ManagedDefaults.managedMode {
                    Text("Managed by organization — some values may be locked via \(ManagedPreferenceKey.domain).")
                        .foregroundStyle(.secondary)
                }
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
        .formStyle(.grouped)
    }
}
