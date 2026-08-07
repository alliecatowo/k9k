import SwiftUI

enum PodTerminalMode { case shell, attach }

/// A Kubernetes exec is a byte stream. The body is intentionally hosted by an
/// AppKit terminal emulator rather than a SwiftUI text control, preserving VT
/// state, colors, keyboard input, copy/paste, mouse reporting, and scrollback.
struct TerminalSessionView: View {
    @Environment(ClusterStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    let resource: ResourceSummary
    let initialMode: PodTerminalMode
    @State private var isStarting = false
    @State private var selectedContainer = ""
    @AppStorage("terminal.preferredShell") private var preferredShell = "/bin/sh"

    private var containers: [String] {
        let spec = resource.raw?.objectValue?["spec"]?.objectValue
        let regular = spec?["containers"]?.arrayValue?.compactMap { $0.objectValue?["name"]?.stringValue } ?? []
        let ephemeral = spec?["ephemeralContainers"]?.arrayValue?.compactMap { $0.objectValue?["name"]?.stringValue } ?? []
        return regular + ephemeral
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(initialMode == .attach ? "Pod Attach" : "Pod Terminal").font(.headline)
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
                Text(initialMode == .attach
                    ? "ANSI/VT terminal · attaches directly to the selected container process"
                    : "ANSI/VT terminal · copy/paste and keyboard input are sent directly to the selected Pod")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                if containers.count > 1 && store.activeExecStreamID == nil {
                    Picker("Container", selection: $selectedContainer) {
                        ForEach(containers, id: \.self) { Text($0).tag($0) }
                    }.frame(maxWidth: 180)
                }
                if initialMode == .shell && store.activeExecStreamID == nil {
                    TextField("Shell program", text: $preferredShell)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 180)
                        .accessibilityLabel("Shell program to execute in the Pod")
                    Menu {
                        Button("POSIX sh (/bin/sh)") { preferredShell = "/bin/sh" }
                        Button("Bash (/bin/bash)") { preferredShell = "/bin/bash" }
                        Button("Almquist shell (/bin/ash)") { preferredShell = "/bin/ash" }
                        Button("Shell from PATH (sh)") { preferredShell = "sh" }
                    } label: {
                        Label("Shell Presets", systemImage: "chevron.down.circle")
                    }
                    .accessibilityLabel("Choose a common shell program")
                }
                if store.activeExecStreamID == nil {
                    Button(initialMode == .attach ? "Attach to Process" : "Start Shell") { startTerminal() }
                        .keyboardShortcut(.defaultAction)
                        .disabled(isStarting || (initialMode == .shell && shellProgram == nil))
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

    private func startTerminal() {
        isStarting = true
        Task {
            if initialMode == .attach {
                await store.openAttach(for: resource, container: selectedContainer)
            } else if let shellProgram {
                // Kubernetes receives an argv vector. Deliberately accept one
                // executable here instead of parsing shell syntax locally.
                await store.openExec(for: resource, command: [shellProgram], container: selectedContainer)
            }
            isStarting = false
        }
    }

    private var shellProgram: String? {
        let program = preferredShell.trimmingCharacters(in: .whitespacesAndNewlines)
        return !program.isEmpty && !program.contains(where: { $0.isWhitespace }) ? program : nil
    }
}
