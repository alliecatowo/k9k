import SwiftUI

/// K9s-compatible node shell without creating an implicit privileged Pod.
/// The operator explicitly chooses a pre-existing, trusted DaemonSet and its
/// container; the core verifies its exact controller ownership and node
/// placement before enabling a terminal.
struct NodeShellView: View {
    @Environment(ClusterStore.self) private var store
    let node: ResourceSummary
    @Binding var isPresented: Bool

    @AppStorage("nodeShell.trustedNamespace") private var namespace = ""
    @AppStorage("nodeShell.trustedDaemonSet") private var daemonSet = ""
    @AppStorage("nodeShell.trustedContainer") private var container = ""
    @State private var isResolving = false
    @State private var terminalPresented = false
    @State private var target: NodeShellTarget?

    private var configurationIsComplete: Bool {
        !namespace.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
        !daemonSet.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
        !container.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Selected node") {
                    LabeledContent("Name", value: node.name)
                    Text("K9k will only resolve a running shell Pod scheduled on this exact node.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Section("Trusted shell target") {
                    TextField("Namespace", text: $namespace, prompt: Text("e.g. platform-tools"))
                    TextField("DaemonSet", text: $daemonSet, prompt: Text("e.g. node-shell"))
                    TextField("Container", text: $container, prompt: Text("e.g. shell"))
                    Text("Choose a DaemonSet your team already deploys and trusts. K9k does not create a debug Pod, choose an image, infer a label selector, or mount host paths for node shells.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Section("Safety checks") {
                    Label("Matches the configured DaemonSet controller UID", systemImage: "checkmark.shield")
                    Label("Is running on the selected node", systemImage: "checkmark.shield")
                    Label("Contains the configured regular container", systemImage: "checkmark.shield")
                    Label("Requires an explicit pods/exec authorization check", systemImage: "checkmark.shield")
                }

                if let target {
                    Section("Verified target") {
                        LabeledContent("Pod", value: target.pod)
                        LabeledContent("Namespace", value: target.namespace)
                        LabeledContent("DaemonSet", value: target.daemonSet)
                        LabeledContent("Container", value: target.container)
                    }
                }
            }
            .formStyle(.grouped)
            .navigationTitle("Node Shell")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Close") { isPresented = false } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Verify & Open Terminal") { resolveTarget() }
                        .disabled(store.isReadOnly || isResolving || !configurationIsComplete)
                }
            }
            .sheet(isPresented: $terminalPresented) {
                if let target { NodeShellTerminalSessionView(target: target) }
            }
        }
        .frame(minWidth: 580, minHeight: 520)
    }

    private func resolveTarget() {
        isResolving = true
        let configuredNamespace = namespace.trimmingCharacters(in: .whitespacesAndNewlines)
        let configuredDaemonSet = daemonSet.trimmingCharacters(in: .whitespacesAndNewlines)
        let configuredContainer = container.trimmingCharacters(in: .whitespacesAndNewlines)
        Task {
            target = await store.resolveNodeShell(
                node: node.name, namespace: configuredNamespace,
                daemonSet: configuredDaemonSet, container: configuredContainer
            )
            terminalPresented = target != nil
            isResolving = false
        }
    }
}

private struct NodeShellTerminalSessionView: View {
    @Environment(ClusterStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    let target: NodeShellTarget
    @State private var isStarting = false
    @AppStorage("terminal.preferredShell") private var preferredShell = "/bin/sh"

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Node Shell").font(.headline)
                    Text("\(target.node) · \(target.namespace)/\(target.pod) · \(target.container)")
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
                Text("ANSI/VT terminal · direct Kubernetes exec into the verified trusted shell Pod")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                if store.activeExecStreamID == nil {
                    TextField("Shell program", text: $preferredShell)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 180)
                        .accessibilityLabel("Shell program to execute in the trusted node shell Pod")
                    Button("Start Shell") { startTerminal() }
                        .keyboardShortcut(.defaultAction)
                        .disabled(isStarting || shellProgram == nil)
                } else {
                    Button("Interrupt") { Task { await store.sendExecInput(Data([3])) } }
                    Button("Disconnect", role: .destructive) { Task { await store.closeExec() } }
                }
            }
            .padding()
        }
        .frame(minWidth: 820, minHeight: 540)
        .onDisappear {
            store.clearTerminalOutputSink()
            Task { await store.closeExec() }
        }
    }

    private func startTerminal() {
        guard let shellProgram else { return }
        isStarting = true
        Task {
            await store.openNodeShell(target: target, command: [shellProgram])
            isStarting = false
        }
    }

    private var shellProgram: String? {
        let program = preferredShell.trimmingCharacters(in: .whitespacesAndNewlines)
        return !program.isEmpty && !program.contains(where: { $0.isWhitespace }) ? program : nil
    }
}
