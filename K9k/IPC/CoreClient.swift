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
    private var process: Process?
    private var input: FileHandle?
    private var buffer = Data()
    private var continuations: [String: CheckedContinuation<CoreEnvelope, Error>] = [:]
    var onEvent: ((CoreEnvelope) -> Void)?

    func start() throws {
        guard process == nil else { return }
        guard let executable = helperURL() else { throw CoreError(code: "helperMissing", message: "K9k’s bundled helper is missing. Run `mise run build` to bundle k9k-core.") }
        let newProcess = Process()
        newProcess.executableURL = executable
        newProcess.arguments = ["serve"]
        let stdin = Pipe(), stdout = Pipe(), stderr = Pipe()
        newProcess.standardInput = stdin
        newProcess.standardOutput = stdout
        newProcess.standardError = stderr
        stdout.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            Task { @MainActor in self?.receive(data) }
        }
        newProcess.terminationHandler = { [weak self] _ in
            Task { @MainActor in self?.failOutstanding(CoreError(code: "helperExited", message: "The K9k Kubernetes helper stopped unexpectedly.")) }
        }
        try newProcess.run()
        process = newProcess
        input = stdin.fileHandleForWriting
    }

    func stop() {
        process?.terminate()
        process = nil
        input?.closeFile()
        input = nil
    }

    func request(_ operation: String, parameters: JSONValue = .object([:])) async throws -> CoreEnvelope {
        try start()
        let id = UUID().uuidString
        let request = CoreRequest(version: 1, id: id, operation: operation, streamID: nil, params: parameters)
        let data = try JSONEncoder().encode(request) + Data([0x0A])
        guard let input else { throw CoreError(code: "transport", message: "K9k could not write to its helper.") }
        return try await withCheckedThrowingContinuation { continuation in
            continuations[id] = continuation
            input.write(data)
        }
    }

    func cancel(streamID: String) async { _ = try? await request("stream.cancel", parameters: .object(["streamID": .string(streamID)])) }

    private func receive(_ data: Data) {
        buffer.append(data)
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
