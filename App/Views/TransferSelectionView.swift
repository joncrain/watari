import AppKit
import SwiftUI
import WatariCore

/// Destination-primary folder picker: peer offered roots after connect.
struct TransferSelectionView: View {
    @EnvironmentObject private var model: AppModel

    private var availableBytes: UInt64? {
        let path = model.receiveFolder?.path
            ?? FileManager.default.homeDirectoryForCurrentUser.path
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

                if model.receiveFolder == nil {
                    Text("Choose a receive folder in Settings before Preview or Start.")
                        .font(.caption)
                        .foregroundStyle(.orange)
                        .padding(.top, 8)
                }

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
                }
                .frame(maxWidth: 540, alignment: .leading)
                .padding(.top, 20)
                .padding(.horizontal, 40)

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
        case .copying:
            return "Transferring selected folders…"
        case .peerGone:
            return "The other Mac disconnected. Reconnect, then Preview again."
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
            comingSoonRow(title: "Dock", systemImage: "dock.rectangle", detail: "Dock layout and items")
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
        return Text("\(selected) selected to transfer. \(available) available on this Mac.")
            .font(.caption)
            .foregroundStyle(.secondary)
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
