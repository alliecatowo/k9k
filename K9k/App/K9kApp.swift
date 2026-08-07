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
        }
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
