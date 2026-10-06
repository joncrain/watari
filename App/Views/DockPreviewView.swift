import AppKit
import SwiftUI
import WatariCore

/// Miniature Genkan-style Dock strip for the Services row.
struct DockPreviewView: View {
    let apps: [DockAppOffer]
    var iconSize: CGFloat = 22
    var emptyText: String = "No Dock apps from source"

    var body: some View {
        Group {
            if apps.isEmpty {
                Text(emptyText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 8)
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 4) {
                        ForEach(apps) { app in
                            DockTile(app: app, size: iconSize)
                        }
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 6)
                }
            }
        }
        .background(
            ZStack {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(.ultraThinMaterial)
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .stroke(Color.primary.opacity(0.08), lineWidth: 0.5)
            }
        )
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityLabel)
    }

    private var accessibilityLabel: String {
        if apps.isEmpty { return emptyText }
        let names = apps.prefix(8).map(\.displayName).joined(separator: ", ")
        let more = apps.count > 8 ? ", and \(apps.count - 8) more" : ""
        return "Source Dock: \(names)\(more)"
    }
}

private struct DockTile: View {
    let app: DockAppOffer
    let size: CGFloat

    var body: some View {
        Group {
            if FileManager.default.fileExists(atPath: app.bundlePath) {
                Image(nsImage: NSWorkspace.shared.icon(forFile: app.bundlePath))
                    .resizable()
                    .interpolation(.high)
                    .aspectRatio(contentMode: .fit)
            } else {
                Image(systemName: "app.dashed")
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(width: size, height: size)
        .help(app.displayName)
    }
}
