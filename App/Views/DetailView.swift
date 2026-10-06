import SwiftUI
import WatariCore

/// Main window: pull-first connect, source prep when offering / inbound, then transfer or summary.
struct DetailView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        Group {
            if model.phase == .transferComplete, let summary = model.lastTransferSummary {
                TransferCompleteView(summary: summary)
            } else if model.shouldShowSourcePrep {
                SourcePrepareView()
            } else if model.selectedPeerID == nil || model.phase == .needsConnect {
                ConnectFirstView()
            } else {
                TransferSelectionView()
            }
        }
        .navigationTitle("Watari")
    }
}
