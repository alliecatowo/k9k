import Foundation

@main
struct WorkspaceGeometryCheck {
    static func main() {
        let cases: [(String, CGFloat, CGFloat, CGFloat)] = [
            // Compact layouts present the inspector as a sheet, so it does
            // not consume the browser's split-view lane.
            ("minimum", WorkspaceGeometry.minimumWindowWidth, WorkspaceGeometry.sidebarMinimumWidth, 0),
            ("default", WorkspaceGeometry.defaultWindowWidth, WorkspaceGeometry.sidebarIdealWidth, WorkspaceGeometry.inspectorIdealWidth),
            ("restored", 1_440, WorkspaceGeometry.sidebarIdealWidth, WorkspaceGeometry.inspectorIdealWidth),
            ("full-screen", 1_512, WorkspaceGeometry.sidebarIdealWidth, WorkspaceGeometry.inspectorIdealWidth),
        ]

        for (name, window, sidebar, inspector) in cases {
            precondition(
                WorkspaceGeometry.hasUsableBrowserWidth(windowWidth: window, sidebarWidth: sidebar, inspectorWidth: inspector),
                "\(name) geometry leaves less than \(WorkspaceGeometry.browserMinimumWidth)pt for the browser"
            )
        }

        precondition(WorkspaceGeometry.usesCompactSideColumns(windowWidth: WorkspaceGeometry.minimumWindowWidth))
        precondition(!WorkspaceGeometry.usesCompactSideColumns(windowWidth: WorkspaceGeometry.idealThreeColumnWindowWidth))
        precondition(
            WorkspaceGeometry.browserWidth(
                windowWidth: WorkspaceGeometry.minimumWindowWidth,
                sidebarWidth: WorkspaceGeometry.sidebarMinimumWidth,
                inspectorWidth: 0
            ) >= WorkspaceGeometry.browserMinimumWidth,
            "compact geometry must preserve the browser minimum while the inspector is in a sheet"
        )
        precondition(
            WorkspaceGeometry.browserWidth(
                windowWidth: WorkspaceGeometry.idealThreeColumnWindowWidth,
                sidebarWidth: WorkspaceGeometry.sidebarIdealWidth,
                inspectorWidth: WorkspaceGeometry.inspectorIdealWidth
            ) == WorkspaceGeometry.browserMinimumWidth,
            "wide in-flow inspector geometry must preserve the browser minimum"
        )
        precondition(
            WorkspaceGeometry.estimatedTableWidth(minimumColumnWidths: [220, 84, 84, 84]) <= WorkspaceGeometry.browserMinimumWidth,
            "compact browser must fit Name plus three operational columns"
        )
        precondition(
            WorkspaceGeometry.estimatedTableWidth(minimumColumnWidths: [220, 84, 84, 84, 84]) > WorkspaceGeometry.browserMinimumWidth,
            "compact browser must drop a low-priority fifth column instead of scrolling Name off-screen"
        )
        precondition(WorkspaceGeometry.quantizedMeasuredWidth(348) == 352)
        precondition(WorkspaceGeometry.quantizedMeasuredWidth(360) == 368)
        precondition(WorkspaceGeometry.quantizedMeasuredWidth(0) == 0)

        let preferredMinimum = WorkspaceGeometry.minimumWindowSize
        let compactScreen = CGRect(x: 0, y: 0, width: 1_364, height: 900)
        let oversizedRestored = CGRect(x: 782, y: 100, width: 1_420, height: 800)
        let compactResult = WorkspaceGeometry.normalizedWindowFrame(
            oversizedRestored,
            visibleFrame: compactScreen,
            preferredMinimumSize: preferredMinimum
        )
        precondition(compactResult.minX >= compactScreen.minX)
        precondition(compactResult.maxX <= compactScreen.maxX)
        precondition(compactResult.width >= preferredMinimum.width)
        precondition(compactResult.width <= compactScreen.width)

        let largeScreen = CGRect(x: 0, y: 0, width: 2_560, height: 1_410)
        let validRestored = CGRect(x: 782, y: 320, width: 1_420, height: 800)
        precondition(
            WorkspaceGeometry.normalizedWindowFrame(
                validRestored,
                visibleFrame: largeScreen,
                preferredMinimumSize: preferredMinimum
            ) == validRestored,
            "a reachable restored frame must remain unchanged"
        )

        let leftDisplay = CGRect(x: -1_600, y: 40, width: 1_600, height: 1_000)
        let displaced = CGRect(x: -1_900, y: -120, width: 1_420, height: 800)
        let leftResult = WorkspaceGeometry.normalizedWindowFrame(
            displaced,
            visibleFrame: leftDisplay,
            preferredMinimumSize: preferredMinimum
        )
        precondition(leftResult.minX >= leftDisplay.minX)
        precondition(leftResult.maxX <= leftDisplay.maxX)
        precondition(leftResult.minY >= leftDisplay.minY)
        precondition(leftResult.maxY <= leftDisplay.maxY)

        let smallerThanPreferred = CGRect(x: 10, y: 20, width: 1_100, height: 600)
        let smallResult = WorkspaceGeometry.normalizedWindowFrame(
            oversizedRestored,
            visibleFrame: smallerThanPreferred,
            preferredMinimumSize: preferredMinimum
        )
        precondition(smallResult == smallerThanPreferred)
        print("Workspace geometry checks passed")
    }
}
