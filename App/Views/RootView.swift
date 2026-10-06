import SwiftUI
import WatariCore

struct RootView: View {
    @EnvironmentObject private var model: AppModel
    @State private var columnVisibility = NavigationSplitViewVisibility.all

    var body: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            SidebarView()
        } detail: {
            DetailView()
        }
        .inspector(isPresented: .constant(true)) {
            InspectorView()
                .inspectorColumnWidth(min: 220, ideal: 260, max: 320)
        }
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                Button("Preview", systemImage: "list.bullet.rectangle") { model.preview() }
                    .disabled(!model.canPreview)
                    .help("Preview what will copy")
                Button("Start", systemImage: "play.fill") { model.start() }
                    .disabled(!model.canStart)
                    .help("Start transfer")
                Button("Stop", systemImage: "stop.fill") { model.stop() }
                    .disabled(!model.canStop)
                    .help("Stop transfer")
            }
            ToolbarItem(placement: .primaryAction) {
                Button("Connect", systemImage: "link") { model.showConnectSheet = true }
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
