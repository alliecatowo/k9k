import SwiftUI
import AppKit

@main
struct K9kApp: App {
    // The browser, operational sidebar, and inspector all carry information
    // that must stay readable at once. This is derived from the same geometry
    // contract as the split-view columns so restored windows cannot compress
    // the table underneath Tahoe's floating sidebar.
    private static let minimumWorkspaceSize = NSSize(
        width: WorkspaceGeometry.minimumWindowSize.width,
        height: WorkspaceGeometry.minimumWindowSize.height
    )

    @State private var store = ClusterStore()

    var body: some Scene {
        WindowGroup("K9k") {
            K9kRootView()
                .environment(store)
                .frame(minWidth: Self.minimumWorkspaceSize.width, minHeight: Self.minimumWorkspaceSize.height)
                .background(WindowSizeConfigurator(minimumSize: Self.minimumWorkspaceSize))
        }
        .defaultSize(width: WorkspaceGeometry.defaultWindowWidth, height: 800)
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
