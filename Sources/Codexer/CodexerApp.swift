import SwiftUI

@main
struct CodexerApp: App {
    @StateObject private var model = CodexerModel()
    @StateObject private var updater = AppUpdater()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(model)
                .environmentObject(updater)
                .frame(minWidth: 900, minHeight: 600)
                .onAppear {
                    NSApp.setActivationPolicy(.regular)
                    NSApp.activate(ignoringOtherApps: true)
                }
        }
        .defaultSize(width: 1080, height: 720)
        .windowStyle(.hiddenTitleBar)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("New Profile") {
                    model.showAddProfile = true
                }
                .keyboardShortcut("n", modifiers: [.command])
            }

            CommandGroup(after: .appInfo) {
                Button("Check for Updates…") {
                    updater.checkForUpdates()
                }
                .disabled(!updater.isConfigured)
            }

            CommandGroup(after: .textEditing) {
                Button("Find…") {
                    NotificationCenter.default.post(name: .agentDockFocusSearch, object: nil)
                }
                .keyboardShortcut("f", modifiers: .command)

                Button("Search Profiles") {
                    NotificationCenter.default.post(name: .agentDockFocusProfileSearch, object: nil)
                }
                .keyboardShortcut("f", modifiers: [.command, .shift])
            }
        }

        Settings {
            SettingsView()
                .environmentObject(model)
                .environmentObject(updater)
        }
        .defaultSize(width: 840, height: 600)
        .windowStyle(.hiddenTitleBar)
    }
}
