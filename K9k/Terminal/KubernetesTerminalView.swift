import AppKit
import SwiftUI
import SwiftTerm

/// SwiftTerm is isolated here so Kubernetes session ownership stays in
/// ClusterStore and no terminal package APIs leak into resource workflows.
struct KubernetesTerminalView: NSViewRepresentable {
    let bindOutput: (@escaping (Data) -> Void) -> Void
    let sendInput: (Data) -> Void
    let resize: (Int, Int) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(sendInput: sendInput, resize: resize)
    }

    func makeNSView(context: Context) -> TerminalView {
        let terminal = TerminalView(frame: .zero)
        terminal.font = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)
        terminal.fontSmoothing = true
        terminal.changeScrollback(10_000)
        terminal.terminalDelegate = context.coordinator
        context.coordinator.terminal = terminal
        bindOutput { [weak terminal] data in
            guard let terminal else { return }
            let bytes = Array(data)
            terminal.feed(byteArray: bytes[...])
        }
        return terminal
    }

    func updateNSView(_ nsView: TerminalView, context: Context) {}

    final class Coordinator: NSObject, TerminalViewDelegate {
        weak var terminal: TerminalView?
        private let sendInput: (Data) -> Void
        private let resize: (Int, Int) -> Void

        init(sendInput: @escaping (Data) -> Void, resize: @escaping (Int, Int) -> Void) {
            self.sendInput = sendInput
            self.resize = resize
        }

        func send(source: TerminalView, data: ArraySlice<UInt8>) {
            sendInput(Data(data))
        }

        func sizeChanged(source: TerminalView, newCols: Int, newRows: Int) {
            resize(newCols, newRows)
        }

        func setTerminalTitle(source: TerminalView, title: String) {}

        func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}

        func scrolled(source: TerminalView, position: Double) {}

        func requestOpenLink(source: TerminalView, link: String, params: [String: String]) {
            guard let url = URL(string: link) else { return }
            NSWorkspace.shared.open(url)
        }

        func bell(source: TerminalView) {}

        func clipboardCopy(source: TerminalView, content: Data) {
            NSPasteboard.general.clearContents()
            if let string = String(data: content, encoding: .utf8) {
                NSPasteboard.general.setString(string, forType: .string)
            }
        }

        // OSC 52 clipboard reads are intentionally denied: a remote Pod must
        // not obtain the Mac clipboard merely because it has an exec session.
        func clipboardRead(source: TerminalView) -> Data? { nil }

        func iTermContent(source: TerminalView, content: ArraySlice<UInt8>) {}

        func rangeChanged(source: TerminalView, startY: Int, endY: Int) {}
    }
}
