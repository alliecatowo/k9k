import SwiftUI

/// A deliberately small terminal surface: Kubernetes owns execution and K9k
/// only relays bytes through its authenticated direct API helper. Keeping the
/// input explicit also makes command history copyable and predictable.
struct TerminalSessionView: View {
    @Environment(ClusterStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    let resource: ResourceSummary
    @State private var command = ""
    @State private var isStarting = false
    @State private var followOutput = true

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Pod Terminal").font(.headline)
                    Text("\(resource.namespace ?? "default") / \(resource.name) · uses the active Kubernetes context")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if store.activeExecStreamID != nil {
                    Label("Connected", systemImage: "checkmark.circle.fill")
                        .font(.caption)
                        .foregroundStyle(.green)
                } else {
                    Label("Disconnected", systemImage: "circle.dashed")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Toggle("Follow", isOn: $followOutput).toggleStyle(.switch).controlSize(.small)
                Button("Close") { dismiss() }
            }
            .padding()
            Divider()

            ScrollViewReader { proxy in
                ScrollView {
                    Text(store.terminalOutput.isEmpty ? "Start a shell to connect to this Pod." : store.terminalOutput)
                        .font(.system(.body, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, minHeight: 330, alignment: .topLeading)
                        .padding(16)
                        .id("terminal-end")
                }
                .background(.black.opacity(0.88))
                .foregroundStyle(.white)
                .onChange(of: store.terminalOutput) { _, _ in
                    guard followOutput else { return }
                    withAnimation(.linear(duration: 0.1)) { proxy.scrollTo("terminal-end", anchor: .bottom) }
                }
            }

            Divider()
            HStack(spacing: 10) {
                TextField("Type a command and press Return", text: $command)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(.body, design: .monospaced))
                    .disabled(store.activeExecStreamID == nil)
                    .onSubmit { submit() }
                Button("Send") { submit() }
                    .disabled(store.activeExecStreamID == nil || command.isEmpty)
                if store.activeExecStreamID == nil {
                    Button("Start Shell") { startShell() }
                        .keyboardShortcut(.defaultAction)
                        .disabled(isStarting)
                } else {
                    Button("Interrupt") { Task { await store.sendExecInput("\u{3}") } }
                    Button("Disconnect", role: .destructive) { Task { await store.closeExec() } }
                }
            }
            .padding()
        }
        .frame(minWidth: 820, minHeight: 540)
        .task { await store.updateExecAccess() }
        .onDisappear { Task { await store.closeExec() } }
    }

    private func startShell() {
        isStarting = true
        Task {
            await store.openExec(for: resource, command: ["/bin/sh"])
            isStarting = false
        }
    }

    private func submit() {
        let submitted = command
        command = ""
        Task { await store.sendExecInput(submitted + "\n") }
    }
}
