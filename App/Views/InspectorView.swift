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
            Section("Exceptions") {
                LabeledContent("In last preview", value: "\(model.exceptionCount)")
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Policy")
    }
}
