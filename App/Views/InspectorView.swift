import SwiftUI
import WatariCore

struct InspectorView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
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
            Section("Permission policy") {
                Toggle("Remap owner to this Mac’s user", isOn: $model.policy.remapOwnerToReceivingUser)
                Text(model.policy.remapOwnerToReceivingUser
                     ? "Files will belong to the receiving Mac’s user. Destination owner is verified after apply."
                     : "Keeping numeric user ids may fail without administrator rights, or leave files owned by a missing user.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Toggle("Keep mode bits", isOn: $model.policy.keepMode)
                Toggle("Keep ACLs when valid", isOn: $model.policy.keepACLs)
                Toggle("Strip quarantine xattr", isOn: $model.policy.stripQuarantine)
                Toggle("Keep other xattrs", isOn: $model.policy.keepExtendedAttributes)
                Toggle("Keep Finder flags", isOn: $model.policy.keepFinderFlags)
            }
            if let item = model.selectedPreviewItem {
                Section("Owners") {
                    LabeledContent("Path", value: item.relativePath)
                    LabeledContent("Source", value: ownerLabel(item.source))
                    LabeledContent("Destination", value: ownerLabel(item.destination))
                    if model.policy.remapOwnerToReceivingUser {
                        Text("On apply, destination owner remaps to this Mac’s user.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            Section("Exceptions") {
                LabeledContent("In last preview", value: "\(model.exceptionCount)")
                LabeledContent("Log events", value: "\(model.jobLog.events.count)")
                Button("Export log…") { model.exportExceptionLog() }
                    .disabled(model.preview == nil && model.jobLog.events.isEmpty)
                Text("JSON Lines audit export: actions plus permission exception codes.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Policy")
    }

    private func ownerLabel(_ meta: FileMetadata?) -> String {
        guard let meta else { return "—" }
        if let name = meta.ownerName {
            return "\(name) (\(meta.uid))"
        }
        return "uid \(meta.uid)"
    }
}
