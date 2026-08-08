import SwiftUI
import AppKit

@main
struct K9kApp: App {
    // The browser, operational sidebar, and inspector all carry information
    // that should stay readable at once. The AppKit configurator treats this
    // as a preferred minimum when the current display can accommodate it and
    // yields to the visible frame on compact or newly attached displays.
    private static let preferredWorkspaceSize = NSSize(
        width: WorkspaceGeometry.minimumWindowSize.width,
        height: WorkspaceGeometry.minimumWindowSize.height
    )

    @State private var store = ClusterStore()

    var body: some Scene {
        WindowGroup("K9k") {
            K9kRootView()
                .environment(store)
                .background(WindowSizeConfigurator(preferredMinimumSize: Self.preferredWorkspaceSize))
        }
        .defaultSize(width: WorkspaceGeometry.defaultWindowWidth, height: 800)
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
