import SwiftUI

/// Shared width contract for K9k's native three-column workspace. Keeping
/// these values in one place makes the AppKit window minimum, split-view
/// columns, and browser content agree instead of allowing a restored window
/// to compress the table beneath a floating navigation surface.
enum WorkspaceGeometry {
    static let sidebarMinimumWidth: CGFloat = 340
    static let sidebarIdealWidth: CGFloat = 380
    static let sidebarMaximumWidth: CGFloat = 480

    static let inspectorMinimumWidth: CGFloat = 360
    static let inspectorIdealWidth: CGFloat = 420
    static let inspectorMaximumWidth: CGFloat = 560

    /// Accommodates a usable Name column plus the minimum Status, Age, and
    /// Kind columns. This is deliberately larger than one cell: Tahoe may
    /// present the sidebar as floating chrome, so the detail must not be the
    /// flexible column that silently loses its leading content.
    static let browserMinimumWidth: CGFloat = 560

    private static let splitDividerAllowance: CGFloat = 20

    // A 1280pt display can still show K9k's wide (340pt minimum) sidebar,
    // 560pt browser, and 360pt inspector. Wider manual sidebar choices are
    // measured at runtime rather than forcing every window above this size.
    static let minimumWindowWidth = sidebarMinimumWidth + browserMinimumWidth + inspectorMinimumWidth + splitDividerAllowance
    static let defaultWindowWidth: CGFloat = 1_280
    static let minimumWindowHeight: CGFloat = 620

    static var minimumWindowSize: CGSize {
        CGSize(width: minimumWindowWidth, height: minimumWindowHeight)
    }

    static func browserWidth(windowWidth: CGFloat, sidebarWidth: CGFloat, inspectorWidth: CGFloat) -> CGFloat {
        max(0, windowWidth - sidebarWidth - inspectorWidth - splitDividerAllowance)
    }

    static func hasUsableBrowserWidth(windowWidth: CGFloat, sidebarWidth: CGFloat, inspectorWidth: CGFloat) -> Bool {
        browserWidth(windowWidth: windowWidth, sidebarWidth: sidebarWidth, inspectorWidth: inspectorWidth) >= browserMinimumWidth
    }
}
