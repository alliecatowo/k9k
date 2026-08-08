import Foundation

@main
struct WorkspaceGeometryCheck {
    static func main() {
        let cases: [(String, CGFloat, CGFloat, CGFloat)] = [
            ("minimum", WorkspaceGeometry.minimumWindowWidth, WorkspaceGeometry.sidebarMinimumWidth, WorkspaceGeometry.inspectorMinimumWidth),
            ("default", WorkspaceGeometry.defaultWindowWidth, WorkspaceGeometry.sidebarMinimumWidth, WorkspaceGeometry.inspectorMinimumWidth),
            ("restored", 1_440, WorkspaceGeometry.sidebarIdealWidth, WorkspaceGeometry.inspectorIdealWidth),
            ("full-screen", 1_512, WorkspaceGeometry.sidebarIdealWidth, WorkspaceGeometry.inspectorIdealWidth),
        ]

        for (name, window, sidebar, inspector) in cases {
            precondition(
                WorkspaceGeometry.hasUsableBrowserWidth(windowWidth: window, sidebarWidth: sidebar, inspectorWidth: inspector),
                "\(name) geometry leaves less than \(WorkspaceGeometry.browserMinimumWidth)pt for the browser"
            )
        }
        print("Workspace geometry checks passed")
    }
}
