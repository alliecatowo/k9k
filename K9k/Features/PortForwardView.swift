import AppKit
import SwiftUI

struct PortForwardView: View {
    @Environment(ClusterStore.self) private var store
    let resource: ResourceSummary
    @Binding var isPresented: Bool
    @State private var remotePort = "80"
    @State private var localPort = "0"
    @State private var isOpening = false

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Port Forward")
                .font(.title2.weight(.semibold))
            Text("\(resource.name) · \(resource.namespace ?? "default")")
                .foregroundStyle(.secondary)

            if let forward = store.activePortForwards.last(where: { $0.binding.namespace == resource.namespace && $0.binding.pod == resource.name }) {
                GroupBox("Active loopback tunnel") {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(forward.binding.endpoint).font(.system(.body, design: .monospaced))
                        Text("Available only on this Mac. It remains active after this sheet closes.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                HStack {
                    Button("Copy Endpoint") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString("http://\(forward.binding.localAddress):\(forward.binding.localPort)", forType: .string)
                    }
                    Button("Open in Browser") {
                        NSWorkspace.shared.open(URL(string: "http://\(forward.binding.localAddress):\(forward.binding.localPort)")!)
                    }
                    Spacer()
                    Button("Stop Forward", role: .destructive) {
                        Task { await store.closePortForward(streamID: forward.streamID) }
                    }
                    Button("Done") { isPresented = false }
                        .keyboardShortcut(.defaultAction)
                }
            } else {
                Form {
                    TextField("Remote Pod Port", text: $remotePort)
                    TextField("Local Port (0 = automatic)", text: $localPort)
                    LabeledContent("Binding", value: "127.0.0.1 only")
                }
                .formStyle(.grouped)
                HStack {
                    Button("Cancel") { isPresented = false }
                    Spacer()
                    Button("Start Forward") { start() }
                        .keyboardShortcut(.defaultAction)
                        .disabled(isOpening)
                }
            }
        }
        .padding(24)
        .frame(width: 460)
    }

    private func start() {
        guard let remote = Int(remotePort), let local = Int(localPort) else {
            store.errorMessage = "Enter numeric port values."
            return
        }
        isOpening = true
        Task {
            await store.openPortForward(for: resource, remotePort: remote, localPort: local)
            isOpening = false
        }
    }
}
