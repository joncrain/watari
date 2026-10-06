import SwiftUI
import WatariCore

/// Main window: connect-first, then peer offer selection.
struct DetailView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        Group {
            if model.selectedPeerID == nil || model.phase == .needsConnect {
                ConnectFirstView()
            } else {
                TransferSelectionView()
            }
        }
        .navigationTitle("Watari")
    }
}
