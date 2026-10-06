import SwiftUI

/// Main window content — single transfer selection panel (no split chrome).
struct DetailView: View {
    var body: some View {
        TransferSelectionView()
            .navigationTitle("Watari")
    }
}
