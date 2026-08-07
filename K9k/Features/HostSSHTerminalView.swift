import Foundation
import SwiftUI

/// A deliberately narrow bridge to the operator's existing macOS OpenSSH
/// setup. K9k neither stores credentials nor guesses a host: the user enters
/// an SSH config alias or a `user@host` target, and `/usr/bin/ssh` uses the
/// existing SSH agent, Keychain integration, and `~/.ssh/config`.
struct HostSSHTerminalView: View {
    @Environment(\.dismiss) private var dismiss
    @AppStorage("hostSSH.target") private var target = ""
    @AppStorage("hostSSH.port") private var port = ""
    @StateObject private var session = HostSSHSession()

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Host SSH").font(.headline)
                    Text(session.status)
                        .font(.caption)
                        .foregroundStyle(session.isConnected ? .green : .secondary)
                        .lineLimit(1)
                }
                Spacer()
                Button("Close") { dismiss() }
                    .disabled(session.isRunning)
            }
            .padding()
            Divider()

            KubernetesTerminalView(
                bindOutput: { sink in session.bindOutput(sink) },
                sendInput: { session.send($0) },
                resize: { _, _ in }
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color.black)

            Divider()
            HStack(spacing: 10) {
                TextField("SSH host or config alias", text: $target, prompt: Text("prod-bastion or ops@prod.example"))
                    .textFieldStyle(.roundedBorder)
                    .frame(minWidth: 280)
                    .disabled(session.isRunning)
                    .accessibilityLabel("SSH host or config alias")
                TextField("Port", text: $port, prompt: Text("22"))
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 84)
                    .disabled(session.isRunning)
                    .accessibilityLabel("SSH port")
                if session.isRunning {
                    Button("Disconnect", role: .destructive) { session.stop() }
                } else {
                    Button("Connect") { session.start(target: target, port: port) }
                        .keyboardShortcut(.defaultAction)
                        .disabled(HostSSHSession.validationMessage(target: target, port: port) != nil)
                }
            }
            .padding(.horizontal)
            .padding(.top, 10)
            if let validation = HostSSHSession.validationMessage(target: target, port: port) {
                Text(validation)
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal)
                    .padding(.bottom, 6)
            }
            Text("K9k starts exactly `/usr/bin/ssh -tt` for this target with BatchMode enabled. It uses your existing SSH config and agent, never stores credentials, does not invoke a shell, and does not pass Kubernetes or cloud environment variables.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal)
                .padding(.bottom, 12)
        }
        .frame(minWidth: 820, minHeight: 540)
        .onDisappear { session.stop() }
    }
}

@MainActor
private final class HostSSHSession: ObservableObject {
    @Published private(set) var status = "Disconnected"
    @Published private(set) var isRunning = false
    @Published private(set) var isConnected = false

    private var process: Process?
    private var input: FileHandle?
    private var output: ((Data) -> Void)?

    func bindOutput(_ sink: @escaping (Data) -> Void) {
        output = sink
    }

    func start(target: String, port: String) {
        guard let validation = Self.validationMessage(target: target, port: port) else {
            status = "Connecting…"
            let process = Process()
            let stdin = Pipe()
            let combinedOutput = Pipe()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
            var arguments = ["-tt", "-o", "BatchMode=yes", "-o", "ConnectTimeout=15"]
            if !port.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                arguments += ["-p", port.trimmingCharacters(in: .whitespacesAndNewlines)]
            }
            arguments.append(target.trimmingCharacters(in: .whitespacesAndNewlines))
            process.arguments = arguments
            process.standardInput = stdin
            process.standardOutput = combinedOutput
            process.standardError = combinedOutput
            process.environment = Self.minimalEnvironment()
            combinedOutput.fileHandleForReading.readabilityHandler = { [weak self] handle in
                let data = handle.availableData
                guard !data.isEmpty else { return }
                Task { @MainActor in self?.output?(data) }
            }
            process.terminationHandler = { [weak self, weak process] process in
                Task { @MainActor in self?.finished(process) }
            }
            do {
                try process.run()
                self.process = process
                input = stdin.fileHandleForWriting
                isRunning = true
                isConnected = true
                status = "Connected to \(target.trimmingCharacters(in: .whitespacesAndNewlines))"
            } catch {
                combinedOutput.fileHandleForReading.readabilityHandler = nil
                status = "Could not start SSH: \(error.localizedDescription)"
                isConnected = false
            }
            return
        }
        status = validation
    }

    func send(_ data: Data) {
        guard isRunning else { return }
        do {
            try input?.write(contentsOf: data)
        } catch {
            status = "SSH input failed: \(error.localizedDescription)"
            stop()
        }
    }

    func stop() {
        let current = process
        process = nil
        input?.closeFile()
        input = nil
        isRunning = false
        isConnected = false
        if current?.isRunning == true { current?.terminate() }
        if status != "Disconnected" { status = "Disconnected" }
    }

    private func finished(_ completed: Process) {
        guard process === completed else { return }
        process = nil
        input?.closeFile()
        input = nil
        isRunning = false
        isConnected = false
        status = completed.terminationStatus == 0 ? "SSH session ended." : "SSH exited with status \(completed.terminationStatus)."
    }

    static func validationMessage(target: String, port: String) -> String? {
        let target = target.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !target.isEmpty else { return "Enter an SSH config alias or user@host target." }
        guard !target.hasPrefix("-"), !target.contains(where: { $0.isWhitespace || $0.isNewline || $0 == "\0" }) else {
            return "The SSH target must be one host or config alias without spaces or options."
        }
        let trimmedPort = port.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmedPort.isEmpty || (Int(trimmedPort).map { (1...65_535).contains($0) } ?? false) else {
            return "Port must be a number from 1 through 65535."
        }
        return nil
    }

    private static func minimalEnvironment() -> [String: String] {
        var environment = [
            "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
            "HOME": NSHomeDirectory(),
            "LANG": ProcessInfo.processInfo.environment["LANG"] ?? "en_US.UTF-8",
        ]
        if let agent = ProcessInfo.processInfo.environment["SSH_AUTH_SOCK"], !agent.isEmpty { environment["SSH_AUTH_SOCK"] = agent }
        if let locale = ProcessInfo.processInfo.environment["LC_ALL"], !locale.isEmpty { environment["LC_ALL"] = locale }
        return environment
    }
}
