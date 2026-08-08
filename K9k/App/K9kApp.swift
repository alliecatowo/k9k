import SwiftUI
import AppKit

@main
struct K9kApp: App {
    // The browser, operational sidebar, and inspector all carry information
    // that must stay readable at once. Below this width AppKit may otherwise
    // compress an inspector despite its preferred column width and clip its
    // segmented control or LabeledContent values.
    private static let minimumWorkspaceSize = NSSize(width: 1_120, height: 620)

    @State private var store = ClusterStore()

    var body: some Scene {
        WindowGroup("K9k") {
            K9kRootView()
                .environment(store)
                .frame(minWidth: Self.minimumWorkspaceSize.width, minHeight: Self.minimumWorkspaceSize.height)
                .background(WindowSizeConfigurator(minimumSize: Self.minimumWorkspaceSize))
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
