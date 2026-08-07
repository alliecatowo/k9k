import Foundation

struct CoreEnvelope: Codable {
    let version: Int
    let id: String?
    let streamID: String?
    let type: String
    let result: JSONValue?
    let error: CoreError?
}

struct CoreError: Codable, Error, LocalizedError {
    let code: String
    let message: String
    var errorDescription: String? { message }
}

@MainActor
final class CoreClient {
    /// One protocol envelope must fit comfortably below macOS pipe pressure.
    /// The Go helper independently bounds all potentially large responses; this
    /// is the client-side guard against a malformed or runaway child process
    /// retaining an unbounded partial NDJSON line on the main actor.
    private static let maximumBufferedEnvelopeBytes = 8 * 1024 * 1024

    private var process: Process?
    private var input: FileHandle?
    private var buffer = Data()
    private var continuations: [String: CheckedContinuation<CoreEnvelope, Error>] = [:]
    var onEvent: ((CoreEnvelope) -> Void)?

    func start() throws {
        if let process, process.isRunning { return }
        // Process termination is delivered asynchronously. If a new request
        // arrives after a child has exited but before its handler reaches the
        // main actor, discard the stale pipe and launch a fresh helper.
        if process != nil {
            resetTransport()
            failOutstanding(CoreError(code: "helperExited", message: "The K9k Kubernetes helper stopped unexpectedly. Retry to relaunch it."))
        }
        guard let executable = helperURL() else { throw CoreError(code: "helperMissing", message: "K9k’s bundled helper is missing. Run `mise run build` to bundle k9k-core.") }
        let newProcess = Process()
        newProcess.executableURL = executable
        newProcess.arguments = ["serve"]
        let stdin = Pipe(), stdout = Pipe(), stderr = Pipe()
        newProcess.standardInput = stdin
        newProcess.standardOutput = stdout
        newProcess.standardError = stderr
        stdout.fileHandleForReading.readabilityHandler = { [weak self, weak newProcess] handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            guard let newProcess else { return }
            Task { @MainActor in self?.receive(data, from: newProcess) }
        }
        newProcess.terminationHandler = { [weak self, weak newProcess] _ in
            guard let newProcess else { return }
            Task { @MainActor in
                self?.helperDidExit(newProcess)
            }
        }
        try newProcess.run()
        process = newProcess
        input = stdin.fileHandleForWriting
    }

    func stop() {
        let current = process
        resetTransport()
        if current?.isRunning == true { current?.terminate() }
        failOutstanding(CoreError(code: "helperStopped", message: "The K9k Kubernetes helper was stopped."))
    }

    func request(_ operation: String, parameters: JSONValue = .object([:])) async throws -> CoreEnvelope {
        try start()
        let id = UUID().uuidString
        let request = CoreRequest(version: 1, id: id, operation: operation, streamID: nil, params: parameters)
        let data = try JSONEncoder().encode(request) + Data([0x0A])
        guard let input else { throw CoreError(code: "transport", message: "K9k could not write to its helper.") }
        return try await withTaskCancellationHandler(operation: {
            try await withCheckedThrowingContinuation { continuation in
                // Cancellation may have occurred while this request was
                // queued for the main actor. Do not leave a continuation that
                // only a future helper response could clear.
                guard !Task.isCancelled else {
                    continuation.resume(throwing: CancellationError())
                    return
                }
                continuations[id] = continuation
                do {
                    try input.write(contentsOf: data)
                } catch {
                    continuations.removeValue(forKey: id)
                    continuation.resume(throwing: CoreError(code: "transport", message: "K9k could not write to its helper."))
                    handleBrokenTransport()
                }
            }
        }, onCancel: { [weak self] in
            Task { @MainActor in self?.cancelPendingRequest(id) }
        })
    }

    func cancel(streamID: String) async { _ = try? await request("stream.cancel", parameters: .object(["streamID": .string(streamID)])) }

    private func receive(_ data: Data, from sourceProcess: Process) {
        // A buffered read from an exited helper can arrive after a successful
        // relaunch. Never let an old child's NDJSON corrupt the new session.
        guard process === sourceProcess else { return }
        buffer.append(data)
        guard buffer.count <= Self.maximumBufferedEnvelopeBytes else {
            handleProtocolViolation("The K9k Kubernetes helper sent an oversized or incomplete protocol message.")
            return
        }
        while let newline = buffer.firstIndex(of: 0x0A) {
            let line = buffer.prefix(upTo: newline)
            buffer.removeSubrange(...newline)
            guard let envelope = try? JSONDecoder.k9k.decode(CoreEnvelope.self, from: line) else { continue }
            if envelope.type == "response", let id = envelope.id, let continuation = continuations.removeValue(forKey: id) {
                if let error = envelope.error { continuation.resume(throwing: error) } else { continuation.resume(returning: envelope) }
            } else { onEvent?(envelope) }
        }
    }

    private func failOutstanding(_ error: Error) {
        let pending = continuations
        continuations.removeAll()
        pending.values.forEach { $0.resume(throwing: error) }
    }

    private func cancelPendingRequest(_ id: String) {
        continuations.removeValue(forKey: id)?.resume(throwing: CancellationError())
    }

    private func helperDidExit(_ exitedProcess: Process) {
        // An old termination handler must never tear down a newer helper that
        // was relaunched after a transient crash.
        guard process === exitedProcess else { return }
        resetTransport()
        failOutstanding(CoreError(code: "helperExited", message: "The K9k Kubernetes helper stopped unexpectedly. Retry to relaunch it."))
    }

    private func handleBrokenTransport() {
        let current = process
        resetTransport()
        if current?.isRunning == true { current?.terminate() }
        failOutstanding(CoreError(code: "transport", message: "K9k lost its connection to the Kubernetes helper. Retry to relaunch it."))
    }

    private func handleProtocolViolation(_ message: String) {
        let current = process
        resetTransport()
        if current?.isRunning == true { current?.terminate() }
        failOutstanding(CoreError(code: "protocol", message: message))
    }

    private func resetTransport() {
        input?.closeFile()
        input = nil
        process = nil
        buffer.removeAll(keepingCapacity: false)
    }

    private func helperURL() -> URL? {
        if let override = ProcessInfo.processInfo.environment["K9K_CORE_PATH"] { return URL(fileURLWithPath: override) }
        return Bundle.main.resourceURL?.appending(path: "k9k-core")
    }
}

private struct CoreRequest: Codable {
    let version: Int
    let id: String
    let operation: String
    let streamID: String?
    let params: JSONValue
}

extension JSONDecoder {
    static let k9k: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()
}
