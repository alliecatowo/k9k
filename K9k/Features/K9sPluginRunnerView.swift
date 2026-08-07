import SwiftUI

/// K9s plugins are user-authored host commands. K9k never launches one on
/// discovery; this sheet makes the exact expanded command visible and requires
/// a deliberate second confirmation before it inherits the app's environment.
struct K9sPluginRunnerView: View {
    @Environment(\.dismiss) private var dismiss
    let plugin: K9sPlugin
    let resource: ResourceSummary
    @State private var confirmRun = false
    @State private var output = ""
    @State private var isRunning = false
    @State private var exitDescription: String?
    @State private var process: Process?

    /// K9s accepts either a complete shell command or a command plus `args`.
    /// Keep the command as authored (it may intentionally use shell syntax),
    /// but quote each separate argument before passing the resulting string to
    /// zsh. This gives placeholders in args the same behaviour as placeholders
    /// in command without letting a resource name change shell syntax.
    private var command: String {
        ([expanded(plugin.command)] + plugin.args.map { shellQuote(expanded($0)) })
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    private func expanded(_ value: String) -> String {
        value
            .replacing("$NAME", with: resource.name)
            .replacing("$NAMESPACE", with: resource.namespace ?? "")
            .replacing("$RESOURCE_NAME", with: resource.name)
            .replacing("$RESOURCE", with: resource.kind.lowercased())
    }

    private func shellQuote(_ value: String) -> String {
        "'" + value.replacing("'", with: "'\\\"'\\\"'") + "'"
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text(plugin.name).font(.headline)
                    Text(plugin.description).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button("Close") { dismiss() }.disabled(isRunning)
            }
            .padding()
            Divider()
            Form {
                Section("Target") {
                    LabeledContent("Resource", value: "\(resource.kind) / \(resource.name)")
                    LabeledContent("Namespace", value: resource.namespace ?? "Cluster-scoped")
                }
                Section("Command") {
                    Text(command).font(.system(.body, design: .monospaced)).textSelection(.enabled)
                    Text("This is a user-configured host command. It can access your shell environment and Kubernetes credentials.")
                        .font(.caption).foregroundStyle(.orange)
                }
            }
            .formStyle(.grouped)
            Divider()
            ScrollView {
                Text(output.isEmpty ? "Output will appear here." : output)
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding()
            }
            .frame(minHeight: 210)
            Divider()
            HStack {
                if let exitDescription { Text(exitDescription).font(.caption).foregroundStyle(.secondary) }
                Spacer()
                if isRunning { Button("Stop", role: .destructive) { process?.terminate() } }
                else { Button("Run Plugin…") { confirmRun = true }.keyboardShortcut(.defaultAction) }
            }
            .padding()
        }
        .frame(minWidth: 760, minHeight: 540)
        .confirmationDialog("Run K9s plugin?", isPresented: $confirmRun, titleVisibility: .visible) {
            Button("Run \(plugin.name)", role: plugin.dangerous ? .destructive : nil) { run() }
        } message: { Text("K9k will run this exact command on your Mac:\n\n\(command)") }
        .onDisappear { process?.terminate() }
    }

    private func run() {
        output = ""
        exitDescription = nil
        isRunning = true
        let command = command
        DispatchQueue.global(qos: .userInitiated).async {
            let process = Process()
            let pipe = Pipe()
            process.executableURL = URL(fileURLWithPath: "/bin/zsh")
            process.arguments = ["-lc", command]
            process.standardOutput = pipe
            process.standardError = pipe
            pipe.fileHandleForReading.readabilityHandler = { handle in
                let data = handle.availableData
                guard !data.isEmpty, let chunk = String(data: data, encoding: .utf8) else { return }
                DispatchQueue.main.async { output.append(chunk) }
            }
            DispatchQueue.main.async { self.process = process }
            do {
                try process.run()
                process.waitUntilExit()
                pipe.fileHandleForReading.readabilityHandler = nil
                let code = process.terminationStatus
                DispatchQueue.main.async {
                    isRunning = false
                    exitDescription = code == 0 ? "Completed successfully." : "Exited with status \(code)."
                    self.process = nil
                }
            } catch {
                DispatchQueue.main.async {
                    isRunning = false
                    exitDescription = "Could not start: \(error.localizedDescription)"
                    self.process = nil
                }
            }
        }
    }
}
