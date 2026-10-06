import SwiftUI
import WatariCore

@main
struct WatariApp: App {
    @StateObject private var appModel = AppModel()

    var body: some Scene {
        WindowGroup("Watari") {
            RootView()
                .environmentObject(appModel)
                .frame(minWidth: 640, minHeight: 520)
                .onAppear { appModel.refreshListener() }
        }
        .commands {
            CommandGroup(replacing: .newItem) {}
            CommandMenu("Job") {
                Button("Preview") { appModel.preview() }
                    .keyboardShortcut("p", modifiers: [.command])
                    .disabled(!appModel.canPreview)
                Button("Start") { appModel.start() }
                    .keyboardShortcut("r", modifiers: [.command])
                    .disabled(!appModel.canStart)
                Button("Stop") { appModel.stop() }
                    .keyboardShortcut(".", modifiers: [.command])
                    .disabled(!appModel.canStop)
            }
        }

        Settings {
            SettingsView()
                .environmentObject(appModel)
        }
    }
}
