import SwiftUI

struct RootView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        DetailView()
            .toolbar {
                ToolbarItemGroup(placement: .primaryAction) {
                    if model.selectedPeerID != nil {
                        Button("Preview", systemImage: "list.bullet.rectangle") { model.preview() }
                            .disabled(!model.canPreview)
                            .help("Preview what will copy")
                        Button("Start", systemImage: "play.fill") { model.start() }
                            .disabled(!model.canStart)
                            .help("Start transfer")
                        if model.canStop {
                            Button("Stop", systemImage: "stop.fill") { model.stop() }
                                .help("Stop transfer")
                        }
                    } else {
                        Button("Connect", systemImage: "link") { model.showConnectSheet = true }
                            .help("Connect a peer Mac")
                    }
                }
                if model.selectedPeerID != nil {
                    ToolbarItem(placement: .primaryAction) {
                        Button("Connect", systemImage: "link") { model.showConnectSheet = true }
                            .help("Connect or change peer")
                    }
                }
            }
            .sheet(isPresented: $model.showConnectSheet) {
                ConnectSheet()
                    .environmentObject(model)
                    .frame(minWidth: 480, minHeight: 360)
            }
            .alert("Error", isPresented: Binding(
                get: { model.lastError != nil },
                set: { if !$0 { model.lastError = nil } }
            )) {
                Button("OK", role: .cancel) { model.lastError = nil }
            } message: {
                Text(model.lastError ?? "")
            }
    }
}
