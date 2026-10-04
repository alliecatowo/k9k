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
    /// The command text is kept as authored (it may intentionally use shell
    /// syntax), but every placeholder value substituted into it is shell-quoted
    /// so a resource name can never change shell syntax. Each arg is expanded
    /// with raw values and then quoted as one whole word.
    private var command: String {
        ([expanded(plugin.command, quoting: true)]
            + plugin.args.map { Self.shellQuote(expanded($0, quoting: false)) })
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    /// Single-pass substitution so a substituted value is never re-expanded and
    /// `$NAMESPACE` is not mistaken for `$NAME` plus a suffix.
    private func expanded(_ value: String, quoting: Bool) -> String {
        value.replacing(/\$(NAMESPACE|RESOURCE_NAME|RESOURCE|NAME)/) { match in
            let raw: String
            switch match.output.1 {
            case "NAMESPACE": raw = resource.namespace ?? ""
            case "RESOURCE": raw = resource.kind.lowercased()
            default: raw = resource.name
            }
            return quoting ? Self.shellQuote(raw) : raw
        }
    }

    /// POSIX single-quote escaping: close the quote, emit an escaped quote, reopen.
    static func shellQuote(_ value: String) -> String {
        "'" + value.replacing("'", with: "'\\''") + "'"
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
