import AppKit
import SwiftUI

// SwiftUI's frame constraints can be compressed by a restored split-view
// window. Apply the minimum to the owning NSWindow so all three columns remain
// usable on first launch and after state restoration.
struct WindowSizeConfigurator: NSViewRepresentable {
    let minimumSize: NSSize

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
        window.minSize = minimumSize
        if window.contentLayoutRect.size.width < minimumSize.width || window.contentLayoutRect.size.height < minimumSize.height {
            window.setContentSize(NSSize(width: max(minimumSize.width, window.contentLayoutRect.width), height: max(minimumSize.height, window.contentLayoutRect.height)))
        }
    }
}
