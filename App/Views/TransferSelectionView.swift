import AppKit
import SwiftUI
import WatariCore

/// Destination-primary folder picker: peer offered roots after connect.
struct TransferSelectionView: View {
    @EnvironmentObject private var model: AppModel

    private var availableBytes: UInt64? {
        let path = model.receiveFolder?.path
            ?? model.destinationHomeURL.path
        if let attrs = try? FileManager.default.attributesOfFileSystem(forPath: path),
           let free = attrs[.systemFreeSize] as? NSNumber {
            return free.uint64Value
        }
        return nil
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

                VStack(alignment: .leading, spacing: 8) {
                    HStack(alignment: .firstTextBaseline) {
                        Text("Folders")
                            .font(.headline)
                        Spacer()
                        if model.isRefreshingOffers {
                            ProgressView()
                                .controlSize(.small)
                        } else {
                            Button("Refresh") { model.refreshPeerOffers() }
                                .help("Reload offered folders from the connected Mac")
                        }
                    }

                    Text(foldersCaption)
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    borderedOfferTree
                        .frame(minHeight: 200, maxHeight: 320)

                    footer

                    receiveAndActions
                }
                .frame(maxWidth: 540, alignment: .leading)
                .padding(.top, 20)
                .padding(.horizontal, 40)

                VStack(alignment: .leading, spacing: 8) {
                    Text("Services")
                        .font(.headline)
                    Text("Checked items run with Start — same transfer plan as folders.")
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
            if model.peerOffers.isEmpty, model.selectedPeerID != nil {
                model.refreshPeerOffers()
            }
        }
    }

    private var foldersCaption: String {
        let source = model.peerOfferDisplayName.isEmpty
            ? (model.selectedPeer?.displayName ?? "the other Mac")
            : model.peerOfferDisplayName
        return "From \(source). Sizes come from that Mac’s folder index."
    }

    private var subtitle: String {
        switch model.phase {
        case .previewReady, .finishedWithExceptions:
            return model.statusMessage
        case .transferComplete:
            return model.statusMessage
        case .copying:
            return "Transferring selected folders…"
        case .peerGone:
            return "The other Mac disconnected. Reconnect to continue."
        case .browsingOffers:
            return model.statusMessage
        case .needsConnect:
            return "Connect to another Mac to continue."
        }
    }

    private var borderedOfferTree: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                if model.peerOffers.isEmpty {
                    Text(model.isRefreshingOffers ? "Loading offered folders…" : "No folders offered yet.")
                        .foregroundStyle(.secondary)
                        .padding(12)
                } else {
                    TransferTreeRow(
                        title: model.peerOfferDisplayName.isEmpty ? "Source Mac" : model.peerOfferDisplayName,
                        systemImage: "laptopcomputer",
                        trailing: totalOffersLabel,
                        depth: 0,
                        isExpanded: .constant(true),
                        canExpand: false,
                        selection: offersSelection,
                        enabled: true,
                        onToggle: { model.setOffersSelected($0, names: model.peerOffers.map(\.name)) }
                    )

                    ForEach(model.peerOffers) { offer in
                        TransferTreeRow(
                            title: offer.name,
                            systemImage: symbol(for: offer.name),
                            trailing: ByteCountFormatter.string(
                                fromByteCount: Int64(offer.totalBytes),
                                countStyle: .file
                            ),
                            depth: 1,
                            isExpanded: .constant(false),
                            canExpand: false,
                            selection: model.isOfferSelected(offer.name) ? .on : .off,
                            enabled: true,
                            onToggle: { model.setOfferSelected($0, name: offer.name) }
                        )
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

    private var borderedServicesList: some View {
        VStack(alignment: .leading, spacing: 0) {
            comingSoonRow(title: "Services", systemImage: "app.dashed", detail: "Mail, Safari, and other apps")
            Divider().padding(.leading, 44)
            dockServiceRow
            Divider().padding(.leading, 44)
            comingSoonRow(title: "Finder", systemImage: "folder", detail: "Finder preferences")
        }
        .padding(.vertical, 4)
        .background(Color(nsColor: .textBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .strokeBorder(Color(nsColor: .separatorColor), lineWidth: 1)
        )
    }

    private var dockServiceRow: some View {
        let enabled = !model.peerDockApps.isEmpty
        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: dockCheckboxSymbol)
                    .font(.body)
                    .foregroundStyle(dockCheckboxColor)
                    .frame(width: 16, height: 16)
                    .accessibilityHidden(true)
                Image(systemName: "dock.rectangle")
                    .foregroundStyle(enabled ? .secondary : .tertiary)
                    .frame(width: 18)
                VStack(alignment: .leading, spacing: 1) {
                    Text("Dock")
                        .foregroundStyle(enabled ? Color.primary : Color.secondary)
                    Text(dockDetail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 8)
                Text(model.peerDockApps.isEmpty ? "Waiting" : "Live")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .contentShape(Rectangle())
            .onTapGesture {
                guard enabled else { return }
                model.setDockTransferSelected(!model.selectedDockTransfer)
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Dock")
            .accessibilityValue(dockAccessibilityValue)
            .accessibilityAddTraits(enabled ? .isButton : [])

            DockPreviewView(
                apps: model.peerDockApps,
                iconSize: 22,
                emptyText: model.selectedPeerID == nil
                    ? "Connect to see the source Dock"
                    : "Source isn’t sending Dock layout yet"
            )
            .padding(.leading, 44)
            .opacity(model.selectedDockTransfer && enabled ? 1 : 0.55)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
    }

    private var dockDetail: String {
        if model.peerDockApps.isEmpty {
            return "Source Dock layout (when connected)"
        }
        if model.selectedDockTransfer {
            return "\(model.peerDockApps.count) apps — included in Start"
        }
        return "\(model.peerDockApps.count) apps — not selected"
    }

    private var dockCheckboxSymbol: String {
        if model.peerDockApps.isEmpty { return "square" }
        return model.selectedDockTransfer ? "checkmark.square.fill" : "square"
    }

    private var dockCheckboxColor: Color {
        if model.peerDockApps.isEmpty { return Color(nsColor: .tertiaryLabelColor) }
        return model.selectedDockTransfer ? Color.accentColor : Color.secondary
    }

    private var dockAccessibilityValue: String {
        if model.peerDockApps.isEmpty { return "waiting for source" }
        return model.selectedDockTransfer ? "selected for Start" : "not selected"
    }

    private func comingSoonRow(title: String, systemImage: String, detail: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "square")
                .font(.body)
                .foregroundStyle(Color(nsColor: .tertiaryLabelColor))
                .frame(width: 16, height: 16)
            Image(systemName: systemImage)
                .foregroundStyle(.tertiary)
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 1) {
                Text(title).foregroundStyle(.secondary)
                Text(detail).font(.caption).foregroundStyle(.tertiary)
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
        let selected = ByteCountFormatter.string(
            fromByteCount: Int64(model.selectedOfferBytes),
            countStyle: .file
        )
        let available: String = {
            if let availableBytes {
                return ByteCountFormatter.string(fromByteCount: Int64(availableBytes), countStyle: .file)
            }
            return "—"
        }()
        let services: String = {
            if model.willApplyDock {
                return " Dock included."
            }
            if model.selectedDockTransfer {
                return " Dock checked (waiting on source)."
            }
            return ""
        }()
        return Text("\(selected) selected to transfer.\(services) \(available) available on this Mac.")
            .font(.caption)
            .foregroundStyle(.secondary)
    }

    /// Home mapping (default) or advanced single-parent override + Start.
    private var receiveAndActions: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Receive on this Mac")
                .font(.subheadline.weight(.medium))

            if model.usesHomeReceiveMapping {
                Text("Under-home folders mirror into your home (Desktop → Desktop). Custom paths outside the source home keep their full absolute path. Ownership remaps to your user.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if !model.selectedOfferNames.isEmpty {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(model.receiveMappingLabels(), id: \.name) { row in
                            Text("\(row.name) → \(row.destinationPath)")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                    }
                }
            } else {
                Text("Advanced override: \(model.receiveFolder?.path ?? "")")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .truncationMode(.middle)
                Button("Use home mapping") { model.clearReceiveFolderOverride() }
                    .font(.caption)
            }

            DisclosureGroup("Advanced receive folder…") {
                Text("Optional. Pick a single parent folder; each offered root becomes a subfolder there instead of matching your home layout.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Button(model.receiveFolder == nil ? "Choose parent folder…" : "Change parent folder…") {
                    model.chooseReceiveFolder()
                }
            }
            .font(.caption)

            HStack(spacing: 12) {
                Button("Start") { model.start() }
                    .buttonStyle(.borderedProminent)
                    .disabled(!model.canStart)
                    .help(model.startBlockedReason ?? "Run the transfer plan (folders and checked Services)")
                    .keyboardShortcut(.defaultAction)
                if model.canStop {
                    Button("Stop", role: .destructive) { model.stop() }
                }
                Spacer(minLength: 0)
            }
            .controlSize(.large)

            if let reason = model.startBlockedReason {
                Text(reason)
                    .font(.caption)
                    .foregroundStyle(.orange)
            } else {
                Text(startHint)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.top, 8)
    }

    private var startHint: String {
        switch (model.selectedOfferNames.isEmpty, model.willApplyDock) {
        case (false, true):
            return "Start pulls selected folders and applies the source Dock."
        case (true, true):
            return "Start applies the source Dock (no folders selected)."
        case (false, false):
            return "Start pulls selected folders."
        case (true, false):
            return "Select folders and/or Dock, then Start."
        }
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
                    "Plan: \(preview.copy) copy · \(preview.update) update · \(preview.unchanged) unchanged · \(preview.skip) skip"
                )
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(maxWidth: 540, alignment: .leading)
            }
        case .peerGone:
            Button("Connect…") { model.showConnectSheet = true }
                .keyboardShortcut(.defaultAction)
        case .transferComplete, .browsingOffers, .needsConnect:
            EmptyView()
        }
    }

    private var offersSelection: RowSelection {
        let names = model.peerOffers.map(\.name)
        guard !names.isEmpty else { return .off }
        let count = names.filter { model.isOfferSelected($0) }.count
        if count == 0 { return .off }
        if count == names.count { return .on }
        return .mixed
    }

    private var totalOffersLabel: String {
        let total = model.peerOffers.reduce(UInt64(0)) { $0 + $1.totalBytes }
        return ByteCountFormatter.string(fromByteCount: Int64(total), countStyle: .file)
    }

    private func symbol(for name: String) -> String {
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

/// Shared whitelist names for source-side offering (Settings / bootstrap).
enum TransferNode {
    static let allowedNames = [
        "Desktop", "Documents", "Downloads", "Pictures", "Movies", "Music", "Public",
    ]
}
