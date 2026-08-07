import SwiftUI
import AppKit

@main
struct K9kApp: App {
    @State private var store = ClusterStore()

    var body: some Scene {
        WindowGroup("K9k") {
            K9kRootView()
                .environment(store)
                .frame(minWidth: 980, minHeight: 620)
                .background(WindowSizeConfigurator(minimumSize: NSSize(width: 980, height: 620)))
        }
        .defaultSize(width: 1280, height: 800)
        .windowResizability(.contentMinSize)
        .commands {
            CommandGroup(after: .newItem) {
                Button("New Cluster Window") {
                    // The window group provides the standard native command entry point.
                }
                .keyboardShortcut("n", modifiers: [.command, .shift])
            }
        }

        Settings {
            SettingsView()
                .environment(store)
        }
    }
}
