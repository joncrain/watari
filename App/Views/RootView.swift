import SwiftUI

struct RootView: View {
    @EnvironmentObject private var model: AppModel
    /// Sidebar hidden by default; user can reveal via toolbar / View menu.
    @State private var columnVisibility: NavigationSplitViewVisibility = .detailOnly
    @State private var showInspector = false

    var body: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            SidebarView()
        } detail: {
            DetailView()
        }
        .inspector(isPresented: $showInspector) {
            InspectorView()
                .inspectorColumnWidth(min: 220, ideal: 260, max: 320)
        }
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
            ToolbarItemGroup(placement: .primaryAction) {
                Button("Sidebar", systemImage: "sidebar.left") {
                    columnVisibility = columnVisibility == .detailOnly ? .all : .detailOnly
                }
                .help(columnVisibility == .detailOnly ? "Show sidebar" : "Hide sidebar")
                Button("Inspector", systemImage: "sidebar.trailing") {
                    showInspector.toggle()
                }
                .help(showInspector ? "Hide inspector" : "Show inspector")
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
