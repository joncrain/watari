import SwiftUI

/// Destination post-job summary — folders transferred plus a few calm stats.
struct TransferCompleteView: View {
    @EnvironmentObject private var model: AppModel
    let summary: TransferCompleteSummary

    var body: some View {
        ScrollView {
            VStack(spacing: 0) {
                Text(summary.hadExceptions ? "Finished with notes" : "Transfer complete")
                    .font(.title2.weight(.semibold))
                    .padding(.top, 36)

                Text("From \(summary.peerDisplayName)")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .padding(.top, 6)

                VStack(alignment: .leading, spacing: 14) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Folders")
                            .font(.headline)
                        ForEach(summary.folderNames, id: \.self) { name in
                            Label(name, systemImage: "folder.fill")
                                .foregroundStyle(.primary)
                        }
                        if summary.folderNames.isEmpty {
                            Text("No folders recorded.")
                                .foregroundStyle(.secondary)
                        }
                    }

                    Divider()

                    VStack(alignment: .leading, spacing: 8) {
                        Text("Summary")
                            .font(.headline)
                        statRow("Files transferred", "\(summary.filesTransferred)")
                        statRow("Size", summary.bytesLabel)
                        statRow("Duration", summary.durationLabel)
                        if summary.unchanged > 0 {
                            statRow("Unchanged", "\(summary.unchanged)")
                        }
                        if summary.skipped > 0 {
                            statRow("Skipped", "\(summary.skipped)")
                        }
                        if summary.permissionRemaps > 0 {
                            statRow("Ownership remapped", "\(summary.permissionRemaps)")
                        }
                        if summary.permissionNotes > 0 {
                            statRow("Permission notes", "\(summary.permissionNotes)")
                        }
                    }
                }
                .frame(maxWidth: 420, alignment: .leading)
                .padding(20)
                .background(Color(nsColor: .textBackgroundColor))
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .strokeBorder(Color(nsColor: .separatorColor), lineWidth: 1)
                )
                .padding(.top, 24)
                .padding(.horizontal, 40)

                HStack(spacing: 12) {
                    Button("Done") { model.dismissTransferSummary() }
                        .buttonStyle(.borderedProminent)
                        .keyboardShortcut(.defaultAction)
                    Button("Transfer more") {
                        model.dismissTransferSummary(keepPeer: true)
                    }
                    .buttonStyle(.bordered)
                }
                .controlSize(.large)
                .padding(.top, 24)
                .padding(.bottom, 36)
            }
            .frame(maxWidth: .infinity)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func statRow(_ title: String, _ value: String) -> some View {
        HStack {
            Text(title)
                .foregroundStyle(.secondary)
            Spacer()
            Text(value)
                .monospacedDigit()
        }
        .font(.callout)
    }
}
