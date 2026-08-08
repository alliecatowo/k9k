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

    static let compactInspectorMinimumWidth: CGFloat = 620
    static let compactInspectorIdealWidth: CGFloat = 700
    static let compactInspectorMinimumHeight: CGFloat = 600
    static let compactInspectorIdealHeight: CGFloat = 700

    /// Accommodates a usable Name column plus the minimum Status, Age, and
    /// Kind columns. This is deliberately larger than one cell: Tahoe may
    /// present the sidebar as floating chrome, so the detail must not be the
    /// flexible column that silently loses its leading content.
    static let browserMinimumWidth: CGFloat = 560

    private static let splitDividerAllowance: CGFloat = 20
    private static let tableChromeAllowance: CGFloat = 24
    private static let tableColumnSpacing: CGFloat = 12
    private static let measuredWidthQuantum: CGFloat = 16

    // A 1280pt display keeps the wide operational sidebar and browser
    // readable; its inspector is a contained sheet. Once the full in-flow
    // inspector and browser all fit, the inspector returns to a resizable,
    // in-flow trailing split surface.
    static let minimumWindowWidth = sidebarMinimumWidth + browserMinimumWidth + inspectorMinimumWidth + splitDividerAllowance
    static let idealThreeColumnWindowWidth = sidebarIdealWidth + browserMinimumWidth + inspectorIdealWidth + splitDividerAllowance
    static let defaultWindowWidth: CGFloat = 1_400
    static let minimumWindowHeight: CGFloat = 620

    static var minimumWindowSize: CGSize {
        CGSize(width: minimumWindowWidth, height: minimumWindowHeight)
    }

    /// Returns a restored window frame that is fully reachable on its current
    /// display. AppKit can restore a frame saved on a larger monitor before
    /// SwiftUI installs the content minimum, leaving the leading sidebar (or
    /// trailing inspector) beyond a smaller display's visible bounds.
    ///
    /// The user's restored size and position are preserved when they already
    /// fit. On a compact display, screen reachability wins over the preferred
    /// three-column minimum so the native sidebar and inspector controls can
    /// still be used to reclaim space.
    static func normalizedWindowFrame(
        _ frame: CGRect,
        visibleFrame: CGRect,
        preferredMinimumSize: CGSize
    ) -> CGRect {
        guard visibleFrame.width > 0, visibleFrame.height > 0 else { return frame }

        let minimumWidth = min(max(preferredMinimumSize.width, 1), visibleFrame.width)
        let minimumHeight = min(max(preferredMinimumSize.height, 1), visibleFrame.height)
        let width = min(max(frame.width, minimumWidth), visibleFrame.width)
        let height = min(max(frame.height, minimumHeight), visibleFrame.height)

        let maximumX = visibleFrame.maxX - width
        let maximumY = visibleFrame.maxY - height
        let x = min(max(frame.minX, visibleFrame.minX), maximumX)
        let y = min(max(frame.minY, visibleFrame.minY), maximumY)
        return CGRect(x: x, y: y, width: width, height: height)
    }

    static func browserWidth(windowWidth: CGFloat, sidebarWidth: CGFloat, inspectorWidth: CGFloat) -> CGFloat {
        max(0, windowWidth - sidebarWidth - inspectorWidth - splitDividerAllowance)
    }

    static func hasUsableBrowserWidth(windowWidth: CGFloat, sidebarWidth: CGFloat, inspectorWidth: CGFloat) -> Bool {
        browserWidth(windowWidth: windowWidth, sidebarWidth: sidebarWidth, inspectorWidth: inspectorWidth) >= browserMinimumWidth
    }

    static func estimatedTableWidth(minimumColumnWidths: [CGFloat]) -> CGFloat {
        guard !minimumColumnWidths.isEmpty else { return 0 }
        let columns = minimumColumnWidths.reduce(0) { $0 + max(0, $1) }
        let spacing = CGFloat(max(0, minimumColumnWidths.count - 1)) * tableColumnSpacing
        return columns + spacing + tableChromeAllowance
    }

    /// Splitters can report every pixel while dragging. Column presence only
    /// changes at much larger thresholds, so round measured side surfaces up
    /// to a conservative bucket and avoid rebuilding the Table per pixel.
    static func quantizedMeasuredWidth(_ width: CGFloat) -> CGFloat {
        guard width.isFinite, width > 0 else { return 0 }
        return ceil(width / measuredWidthQuantum) * measuredWidthQuantum
    }

    static func usesCompactSideColumns(windowWidth: CGFloat) -> Bool {
        windowWidth < idealThreeColumnWindowWidth
    }
}
