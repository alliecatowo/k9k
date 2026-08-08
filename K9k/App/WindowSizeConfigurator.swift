import AppKit
import SwiftUI

// SwiftUI restores the last frame before laying out a NavigationSplitView. A
// frame saved on a larger display can put the leading sidebar beyond a compact
// display, so configure both the preferred minimum and screen reachability on
// the owning NSWindow.
struct WindowSizeConfigurator: NSViewRepresentable {
    let preferredMinimumSize: NSSize

    func makeNSView(context: Context) -> NSView {
        let view = NSView(frame: .zero)
        DispatchQueue.main.async { configure(view.window) }
        return view
    }

    func updateNSView(_ view: NSView, context: Context) {
        DispatchQueue.main.async { configure(view.window) }
    }

    private func configure(_ window: NSWindow?) {
        guard let window else { return }
        guard let screen = window.screen ?? NSScreen.main else {
            window.minSize = preferredMinimumSize
            return
        }

        let visibleFrame = screen.visibleFrame
        // A screen can be smaller than the preferred three-column workspace.
        // Never make the minimum itself larger than the reachable display.
        window.minSize = NSSize(
            width: min(preferredMinimumSize.width, visibleFrame.width),
            height: min(preferredMinimumSize.height, visibleFrame.height)
        )

        let normalized = WorkspaceGeometry.normalizedWindowFrame(
            window.frame,
            visibleFrame: visibleFrame,
            preferredMinimumSize: preferredMinimumSize
        )
        let constrained = window.constrainFrameRect(normalized, to: screen)
        if !window.frame.equalTo(constrained) {
            window.setFrame(constrained, display: true)
        }
    }
}
