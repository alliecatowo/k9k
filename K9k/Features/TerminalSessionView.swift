import SwiftUI

/// A Kubernetes exec is a byte stream. The body is intentionally hosted by an
/// AppKit terminal emulator rather than a SwiftUI text control, preserving VT
/// state, colors, keyboard input, copy/paste, mouse reporting, and scrollback.
struct TerminalSessionView: View {
    @Environment(ClusterStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    let resource: ResourceSummary
    @State private var isStarting = false
    @State private var selectedContainer = ""

    private var containers: [String] {
        resource.raw?.objectValue?["spec"]?.objectValue?["containers"]?.arrayValue?.compactMap { $0.objectValue?["name"]?.stringValue } ?? []
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Pod Terminal").font(.headline)
                    Text("\(resource.namespace ?? "default") / \(resource.name) · active Kubernetes context")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Label(store.activeExecStreamID == nil ? "Disconnected" : "Connected", systemImage: store.activeExecStreamID == nil ? "circle.dashed" : "checkmark.circle.fill")
                    .font(.caption)
                    .foregroundStyle(store.activeExecStreamID == nil ? Color.secondary : Color.green)
                Button("Close") { dismiss() }
            }
            .padding()
            Divider()

            KubernetesTerminalView(
                bindOutput: { sink in store.setTerminalOutputSink(sink) },
                sendInput: { data in Task { await store.sendExecInput(data) } },
                resize: { columns, rows in Task { await store.resizeExec(columns: columns, rows: rows) } }
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color.black)

            Divider()
            HStack(spacing: 10) {
                Text("ANSI/VT terminal · copy/paste and keyboard input are sent directly to the selected Pod")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                if containers.count > 1 && store.activeExecStreamID == nil {
                    Picker("Container", selection: $selectedContainer) {
                        ForEach(containers, id: \.self) { Text($0).tag($0) }
                    }.frame(maxWidth: 180)
                }
                if store.activeExecStreamID == nil {
                    Button("Start Shell") { startShell() }
                        .keyboardShortcut(.defaultAction)
                        .disabled(isStarting)
                } else {
                    Button("Interrupt") { Task { await store.sendExecInput(Data([3])) } }
                    Button("Disconnect", role: .destructive) { Task { await store.closeExec() } }
                }
            }
            .padding()
        }
        .frame(minWidth: 820, minHeight: 540)
        .onAppear { if selectedContainer.isEmpty { selectedContainer = containers.first ?? "" } }
        .task { await store.updateExecAccess() }
        .onDisappear {
            store.clearTerminalOutputSink()
            Task { await store.closeExec() }
        }
    }

    private func startShell() {
        isStarting = true
        Task {
            await store.openExec(for: resource, command: ["/bin/sh"], container: selectedContainer)
            isStarting = false
        }
    }
}
