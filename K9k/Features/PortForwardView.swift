import AppKit
import SwiftUI

struct PortForwardView: View {
    @Environment(ClusterStore.self) private var store
    let resource: ResourceSummary
    @Binding var isPresented: Bool
    @State private var remotePort = "80"
    @State private var localPort = "0"
    @State private var isOpening = false
    @State private var openedForwardID: ActivePortForward.ID?

    private var isService: Bool { resource.kind == "Service" }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Port Forward")
                .font(.title2.weight(.semibold))
            Text("\(resource.name) · \(resource.namespace ?? "default")")
                .foregroundStyle(.secondary)

            if let active = openedForwardID.flatMap({ id in store.activePortForwards.first(where: { $0.id == id }) })
                ?? store.activePortForwards.last(where: { $0.binding.namespace == resource.namespace && $0.binding.pod == resource.name }) {
                let forward = active.binding
                GroupBox("Active loopback tunnel") {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(forward.endpoint).font(.system(.body, design: .monospaced))
                        Text(active.connectionState.detail)
                            .foregroundStyle(active.connectionState.isConnected ? .green : .orange)
                        Text(active.connectionState.isConnected ? "Available only on this Mac. It remains active after this sheet closes." : "K9k is preserving this forward and will retry with bounded backoff.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                HStack {
                    Button("Copy Endpoint") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString("http://\(forward.localAddress):\(forward.localPort)", forType: .string)
                    }
                    .disabled(!active.connectionState.isConnected)
                    Button("Open in Browser") {
                        NSWorkspace.shared.open(URL(string: "http://\(forward.localAddress):\(forward.localPort)")!)
                    }
                    .disabled(!active.connectionState.isConnected)
                    Spacer()
                    if !active.connectionState.isConnected {
                        Button("Retry Now") { store.retryPortForward(id: active.id) }
                    }
                    Button("Stop Forward", role: .destructive) { Task { await store.closePortForward(streamID: active.streamID) } }
                    Button("Done") { isPresented = false }
                        .keyboardShortcut(.defaultAction)
                }
            } else {
                Form {
                    TextField(isService ? "Service Port" : "Remote Pod Port", text: $remotePort)
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
            openedForwardID = await store.openPortForward(for: resource, remotePort: remote, localPort: local)?.id
            isOpening = false
        }
    }
}
