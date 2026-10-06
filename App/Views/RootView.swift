import SwiftUI

struct RootView: View {
    @EnvironmentObject private var model: AppModel
    /// Custom sidebar — avoid NavigationSplitView’s system `>>` toggle.
    @State private var showSidebar = false
    @State private var showInspector = false

    var body: some View {
        HStack(spacing: 0) {
            if showSidebar {
                SidebarView()
                    .frame(width: 220)
                    .background(.background)
                Divider()
            }

            DetailView()
                .frame(maxWidth: .infinity, maxHeight: .infinity)

            if showInspector {
                Divider()
                InspectorView()
                    .frame(width: 260)
                    .background(.background)
            }
        }
        .toolbar {
            ToolbarItem(placement: .navigation) {
                Button {
                    showSidebar.toggle()
                } label: {
                    Label(showSidebar ? "Hide Sidebar" : "Show Sidebar", systemImage: "sidebar.left")
                }
                .help(showSidebar ? "Hide sidebar" : "Show sidebar")
            }

            ToolbarItemGroup(placement: .primaryAction) {
                if model.selectedPeerID != nil, model.phase != .transferComplete, !model.shouldShowSourcePrep {
                    Button("Preview", systemImage: "list.bullet.rectangle") { model.preview() }
                        .disabled(!model.canPreview)
                        .help(model.previewBlockedReason ?? "Preview what will copy from the source Mac")
                    Button("Start", systemImage: "play.fill") { model.start() }
                        .disabled(!model.canStart)
                        .help(model.startBlockedReason ?? "Pull selected folders to this Mac")
                    if model.canStop {
                        Button("Stop", systemImage: "stop.fill") { model.stop() }
                            .help("Stop transfer")
                    }
                    Button("Connect", systemImage: "link") { model.showConnectSheet = true }
                        .help("Connect or change peer")
                } else if !model.shouldShowSourcePrep {
                    Button("Connect", systemImage: "link") { model.showConnectSheet = true }
                        .help("Connect to a source Mac")
                }

                Button {
                    showInspector.toggle()
                } label: {
                    Label(
                        showInspector ? "Hide Inspector" : "Show Inspector",
                        systemImage: "sidebar.trailing"
                    )
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
