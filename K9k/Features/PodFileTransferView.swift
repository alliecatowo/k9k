import AppKit
import Foundation
import Observation
import SwiftUI
import UniformTypeIdentifiers

/// A direct, binary-safe counterpart to K9s' `cp` action. Files move through
/// the existing client-go `pods/exec` transport as a tar byte stream; neither
/// this UI nor the bundled helper invokes kubectl or a local shell.
struct PodFileTransferView: View {
    @Environment(ClusterStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    let resource: ResourceSummary

    @State private var controller = PodFileTransferController()
    @State private var selectedContainer = ""
    @State private var remotePath = "/tmp"
    @State private var localURL: URL?
    @State private var downloadDirectory: URL?
    @State private var importing = false
    @State private var access: AccessReview?

    private var containers: [String] {
        let spec = resource.raw?.objectValue?["spec"]?.objectValue
        return (spec?["containers"]?.arrayValue ?? []).compactMap { $0.objectValue?["name"]?.stringValue }
    }

    private var targetSummary: String {
        "\(resource.namespace ?? "default") / \(resource.name)"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 12) {
                Image(systemName: "arrow.left.arrow.right.circle.fill")
                    .font(.title2)
                    .foregroundStyle(.tint)
                VStack(alignment: .leading, spacing: 3) {
                    Text("Pod File Transfer").font(.headline)
                    Text("\(targetSummary) · direct tar stream over Kubernetes exec")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button("Close") { dismiss() }
            }
            .padding()
            Divider()

            Form {
                Section("Target") {
                    LabeledContent("Pod", value: targetSummary)
                    if containers.count > 1 {
                        Picker("Container", selection: $selectedContainer) {
                            ForEach(containers, id: \.self) { Text($0).tag($0) }
                        }
                    } else {
                        LabeledContent("Container", value: containers.first ?? "Kubernetes default")
                    }
                }

                Section("Upload to Pod") {
                    LabeledContent("Local item") {
                        HStack {
                            Text(localURL?.lastPathComponent ?? "No file or folder selected")
                                .lineLimit(1).foregroundStyle(localURL == nil ? .secondary : .primary)
                            Spacer()
                            Button("Choose…") { importing = true }.disabled(controller.isWorking)
                        }
                    }
                    TextField("Existing remote directory", text: $remotePath)
                        .textFieldStyle(.roundedBorder)
                        .disabled(controller.isWorking)
                    Text("K9k creates a regular-file/directory tar archive locally and extracts it only into this existing absolute directory. Symlinks, special files, traversal paths, and archives over 1 GiB are refused.")
                        .font(.caption).foregroundStyle(.secondary)
                    Button("Upload") {
                        guard let localURL else { return }
                        Task { await upload(localURL) }
                    }
                    .disabled(controller.isWorking || localURL == nil || !canTransfer)
                }

                Section("Download from Pod") {
                    TextField("Absolute remote file or directory", text: $remotePath)
                        .textFieldStyle(.roundedBorder)
                        .disabled(controller.isWorking)
                    LabeledContent("Local folder") {
                        HStack {
                            Text(downloadDirectory?.path ?? "No destination selected")
                                .lineLimit(1).foregroundStyle(downloadDirectory == nil ? .secondary : .primary)
                            Spacer()
                            Button("Choose…") { chooseDownloadDirectory() }.disabled(controller.isWorking)
                        }
                    }
                    Text("K9k verifies every returned tar header before extraction and writes only regular files/directories below the folder you chose. Existing destination names are never overwritten.")
                        .font(.caption).foregroundStyle(.secondary)
                    Button("Download") {
                        guard let downloadDirectory else { return }
                        Task { await download(to: downloadDirectory) }
                    }
                    .disabled(controller.isWorking || downloadDirectory == nil || !canTransfer)
                }

                Section("Access") {
                    if store.isReadOnly {
                        Label("Read-only mode blocks Pod file transfer.", systemImage: "lock.fill")
                            .foregroundStyle(.orange)
                    } else if let access {
                        Label(access.allowed ? "pods/exec authorized" : (access.reason ?? "pods/exec was not authorized"), systemImage: access.allowed ? "checkmark.shield.fill" : "xmark.shield.fill")
                            .foregroundStyle(access.allowed ? .green : .red)
                    } else {
                        ProgressView("Checking pods/exec permission…")
                    }
                }
            }
            .formStyle(.grouped)

            if controller.isWorking || controller.message != nil || controller.errorMessage != nil {
                Divider()
                HStack(spacing: 10) {
                    if controller.isWorking { ProgressView().controlSize(.small) }
                    Text(controller.errorMessage ?? controller.message ?? "Ready")
                        .font(.caption)
                        .foregroundStyle(controller.errorMessage == nil ? Color.secondary : Color.red)
                        .lineLimit(2)
                    Spacer()
                    if controller.isWorking {
                        Button("Cancel", role: .destructive) { Task { await controller.cancel() } }
                    }
                }
                .padding()
            }
        }
        .frame(minWidth: 620, minHeight: 620)
        .onAppear {
            if selectedContainer.isEmpty { selectedContainer = containers.first ?? "" }
        }
        .task { access = await store.podExecAccess(for: resource) }
        .fileImporter(isPresented: $importing, allowedContentTypes: [.item], allowsMultipleSelection: false) { result in
            switch result {
            case .success(let urls): localURL = urls.first
            case .failure(let error): controller.errorMessage = error.localizedDescription
            }
        }
        .onDisappear { Task { await controller.cancel() } }
    }

    private var canTransfer: Bool { !store.isReadOnly && access?.allowed == true }

    private func upload(_ url: URL) async {
        await controller.upload(localURL: url, to: remotePath, resource: resource, container: selectedContainer)
    }

    private func download(to directory: URL) async {
        await controller.download(remotePath: remotePath, into: directory, resource: resource, container: selectedContainer)
    }

    private func chooseDownloadDirectory() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Choose Destination"
        if panel.runModal() == .OK { downloadDirectory = panel.url }
    }
}

@MainActor
@Observable
final class PodFileTransferController {
    private static let chunkSize = 48 * 1024
    private static let maxArchiveBytes: UInt64 = 1 << 30

    var isWorking = false
    var message: String?
    var errorMessage: String?

    private let client = CoreClient()
    private var streamID: String?
    private var downloadHandle: FileHandle?
    private var downloadURL: URL?
    private var bytesReceived: UInt64 = 0
    private var closeResult: Result<Void, Error>?
    private var closeContinuation: CheckedContinuation<Void, Error>?

    init() {
        client.onEvent = { [weak self] envelope in self?.receive(envelope) }
    }

    func upload(localURL: URL, to remoteDirectory: String, resource: ResourceSummary, container: String) async {
        await run("Uploading \(localURL.lastPathComponent)…") {
            let destination = try PodTransferPath.directory(remoteDirectory)
            let archive = try TarArchive.create(from: localURL, maximumBytes: Self.maxArchiveBytes)
            defer { try? FileManager.default.removeItem(at: archive) }
            try await open(resource: resource, container: container, command: ["tar", "-x", "-f", "-", "-C", destination], stdin: true)
            let input = try FileHandle(forReadingFrom: archive)
            defer { try? input.close() }
            while let bytes = try input.read(upToCount: Self.chunkSize), !bytes.isEmpty {
                try Task.checkCancellation()
                _ = try await client.request("exec.stdin", parameters: .object([
                    "streamID": .string(try activeStreamID()), "dataBase64": .string(bytes.base64EncodedString())
                ]))
            }
            _ = try await client.request("exec.stdin.close", parameters: .object(["streamID": .string(try activeStreamID())]))
            try await waitForClose()
            message = "Uploaded \(localURL.lastPathComponent) to \(destination)."
        }
    }

    func download(remotePath: String, into localDirectory: URL, resource: ResourceSummary, container: String) async {
        await run("Downloading…") {
            let source = try PodTransferPath.item(remotePath)
            guard FileManager.default.fileExists(atPath: localDirectory.path) else {
                throw PodTransferError("The selected local destination no longer exists.")
            }
            let archive = FileManager.default.temporaryDirectory.appendingPathComponent("k9k-download-\(UUID().uuidString).tar")
            FileManager.default.createFile(atPath: archive.path, contents: nil)
            let output = try FileHandle(forWritingTo: archive)
            downloadHandle = output
            downloadURL = archive
            bytesReceived = 0
            defer {
                try? output.close()
                downloadHandle = nil
                downloadURL = nil
                try? FileManager.default.removeItem(at: archive)
            }
            try await open(resource: resource, container: container, command: ["tar", "-c", "-f", "-", "-C", source.parent, source.leaf], stdin: false)
            try await waitForClose()
            try TarArchive.extract(archive, into: localDirectory, expectedTopLevel: source.leaf, maximumBytes: Self.maxArchiveBytes)
            message = "Downloaded \(source.leaf) into \(localDirectory.path)."
        }
    }

    func cancel() async {
        guard let streamID else { return }
        await client.cancel(streamID: streamID)
    }

    private func run(_ startingMessage: String, operation: () async throws -> Void) async {
        guard !isWorking else { return }
        isWorking = true
        message = startingMessage
        errorMessage = nil
        defer {
            isWorking = false
            streamID = nil
            closeResult = nil
            closeContinuation = nil
        }
        do {
            try await operation()
        } catch is CancellationError {
            await cancel()
            message = "Transfer cancelled."
        } catch {
            await cancel()
            errorMessage = error.localizedDescription
        }
    }

    private func open(resource: ResourceSummary, container: String, command: [String], stdin: Bool) async throws {
        guard resource.kind == "Pod", let namespace = resource.namespace else { throw PodTransferError("A namespaced Pod is required.") }
        let id = UUID().uuidString
        streamID = id
        closeResult = nil
        var parameters: [String: JSONValue] = [
            "streamID": .string(id), "namespace": .string(namespace), "pod": .string(resource.name),
            "command": .array(command.map(JSONValue.string)), "tty": .bool(false), "stdin": .bool(stdin)
        ]
        if !container.isEmpty { parameters["container"] = .string(container) }
        _ = try await client.request("exec.open", parameters: .object(parameters))
    }

    private func activeStreamID() throws -> String {
        guard let streamID else { throw PodTransferError("The transfer stream is no longer active.") }
        return streamID
    }

    private func waitForClose() async throws {
        if let closeResult { return try closeResult.get() }
        try await withCheckedThrowingContinuation { continuation in closeContinuation = continuation }
    }

    private func receive(_ event: CoreEnvelope) {
        guard event.streamID == streamID else { return }
        switch event.type {
        case "exec.stdout":
            guard let encoded = event.result?.objectValue?["dataBase64"]?.stringValue,
                  let bytes = Data(base64Encoded: encoded), let output = downloadHandle else { return }
            bytesReceived += UInt64(bytes.count)
            if bytesReceived > Self.maxArchiveBytes {
                finish(.failure(PodTransferError("The remote archive exceeds K9k’s 1 GiB transfer limit.")))
                Task { await cancel() }
                return
            }
            do { try output.write(contentsOf: bytes) }
            catch { finish(.failure(error)) }
        case "exec.error":
            let remoteMessage = event.result?.objectValue?["message"]?.stringValue ?? "The remote tar command failed."
            finish(.failure(PodTransferError(remoteMessage)))
        case "exec.closed":
            let reason = event.result?.objectValue?["reason"]?.stringValue ?? "error"
            finish(reason == "completed" ? .success(()) : .failure(PodTransferError("Transfer ended: \(reason).")))
        default: break
        }
    }

    private func finish(_ result: Result<Void, Error>) {
        guard closeResult == nil else { return }
        closeResult = result
        if let closeContinuation {
            self.closeContinuation = nil
            switch result {
            case .success: closeContinuation.resume()
            case .failure(let error): closeContinuation.resume(throwing: error)
            }
        }
    }
}

private struct PodTransferError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

private struct PodTransferPath {
    let parent: String
    let leaf: String

    static func directory(_ input: String) throws -> String {
        let path = try normalizedAbsolutePath(input)
        return path
    }

    static func item(_ input: String) throws -> PodTransferPath {
        let path = try normalizedAbsolutePath(input)
        guard path != "/" else { throw PodTransferError("Downloading the filesystem root is not allowed.") }
        let components = path.split(separator: "/").map(String.init)
        guard let leaf = components.last else { throw PodTransferError("A remote file or directory is required.") }
        let parent = components.dropLast().isEmpty ? "/" : "/" + components.dropLast().joined(separator: "/")
        return PodTransferPath(parent: parent, leaf: leaf)
    }

    private static func normalizedAbsolutePath(_ input: String) throws -> String {
        let path = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard path.utf8.count <= 4096, path.hasPrefix("/"), !path.contains("\0") else {
            throw PodTransferError("Use an absolute remote path shorter than 4097 bytes.")
        }
        let components = path.split(separator: "/", omittingEmptySubsequences: true)
        guard !components.contains(where: { $0 == "." || $0 == ".." }) else {
            throw PodTransferError("Remote paths may not contain . or .. components.")
        }
        return "/" + components.joined(separator: "/")
    }
}

/// Minimal USTAR reader/writer for regular files and directories. Limiting the
/// archive format is intentional: accepting symlinks, devices, hard links, or
/// PAX path rewrites would make extraction safety dependent on an untrusted
/// container. This keeps both sides deterministic and traversal-safe.
private enum TarArchive {
    private static let blockSize = 512

    static func create(from root: URL, maximumBytes: UInt64) throws -> URL {
        let access = root.startAccessingSecurityScopedResource()
        defer { if access { root.stopAccessingSecurityScopedResource() } }
        let name = root.lastPathComponent
        try validateArchivePath(name)
        let archive = FileManager.default.temporaryDirectory.appendingPathComponent("k9k-upload-\(UUID().uuidString).tar")
        FileManager.default.createFile(atPath: archive.path, contents: nil)
        do {
            let output = try FileHandle(forWritingTo: archive)
            defer { try? output.close() }
            var written: UInt64 = 0
            try append(root, archivePath: name, output: output, written: &written, maximumBytes: maximumBytes)
            try output.write(contentsOf: Data(repeating: 0, count: blockSize * 2))
            // The payload budget above intentionally counts regular-file
            // bytes while building. Account for headers and padding as well
            // before exposing the archive to the exec stream.
            try output.synchronize()
            let archiveBytes = UInt64((try FileManager.default.attributesOfItem(atPath: archive.path)[.size] as? NSNumber)?.uint64Value ?? 0)
            guard archiveBytes <= maximumBytes else { throw PodTransferError("Local archive exceeds K9k’s 1 GiB transfer limit.") }
            return archive
        } catch {
            try? FileManager.default.removeItem(at: archive)
            throw error
        }
    }

    static func extract(_ archive: URL, into destination: URL, expectedTopLevel: String, maximumBytes: UInt64) throws {
        try validateArchivePath(expectedTopLevel)
        let input = try FileHandle(forReadingFrom: archive)
        defer { try? input.close() }
        let fm = FileManager.default
        var total: UInt64 = 0
        var count = 0
        var created = Set<String>()
        var createdRoot = false
        do {
            while let header = try readExactly(input, count: blockSize) {
                if header.allSatisfy({ $0 == 0 }) { break }
                let entry = try parseHeader(header)
                let parts = entry.path.split(separator: "/").map(String.init)
                guard parts.first == expectedTopLevel else { throw PodTransferError("Remote archive contains an unexpected top-level path.") }
                try validateArchivePath(entry.path)
                count += 1
                guard count <= 10_000 else { throw PodTransferError("Remote archive contains too many entries.") }
                total += entry.size
                guard total <= maximumBytes else { throw PodTransferError("The remote archive exceeds K9k’s 1 GiB transfer limit.") }

                let target = destination.appendingPathComponent(entry.path)
                let targetPath = target.standardizedFileURL.path
                let base = destination.standardizedFileURL.path + "/"
                guard targetPath.hasPrefix(base) else { throw PodTransferError("Archive path escapes the selected destination.") }
                switch entry.kind {
                case .directory:
                    if fm.fileExists(atPath: target.path), !created.contains(target.path) { throw PodTransferError("Download would overwrite \(entry.path).") }
                    try fm.createDirectory(at: target, withIntermediateDirectories: true)
                    created.insert(target.path)
                    if parts.count == 1 { createdRoot = true }
                    try skip(input, count: entry.size)
                case .file:
                    let parent = target.deletingLastPathComponent()
                    if !fm.fileExists(atPath: parent.path) { try fm.createDirectory(at: parent, withIntermediateDirectories: true) }
                    if fm.fileExists(atPath: target.path) { throw PodTransferError("Download would overwrite \(entry.path).") }
                    guard fm.createFile(atPath: target.path, contents: nil), let output = try? FileHandle(forWritingTo: target) else {
                        throw PodTransferError("K9k could not create \(entry.path).")
                    }
                    defer { try? output.close() }
                    try copy(input, to: output, count: entry.size)
                    created.insert(target.path)
                    if parts.count == 1 { createdRoot = true }
                }
                let padding = (UInt64(blockSize) - entry.size % UInt64(blockSize)) % UInt64(blockSize)
                try skip(input, count: padding)
            }
            guard createdRoot else { throw PodTransferError("Remote tar output did not contain the requested path.") }
        } catch {
            if createdRoot { try? fm.removeItem(at: destination.appendingPathComponent(expectedTopLevel)) }
            throw error
        }
    }

    private static func append(_ url: URL, archivePath: String, output: FileHandle, written: inout UInt64, maximumBytes: UInt64) throws {
        let values = try url.resourceValues(forKeys: [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey, .contentModificationDateKey])
        guard values.isSymbolicLink != true else { throw PodTransferError("Local symlinks are not supported for safe Pod transfer: \(url.lastPathComponent)") }
        if values.isDirectory == true {
            try writeHeader(path: archivePath + "/", size: 0, directory: true, modified: values.contentModificationDate, to: output)
            for child in try FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: nil).sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
                try append(child, archivePath: archivePath + "/" + child.lastPathComponent, output: output, written: &written, maximumBytes: maximumBytes)
            }
        } else if values.isRegularFile == true {
            let size = UInt64(values.fileSize ?? 0)
            written += size
            guard written <= maximumBytes else { throw PodTransferError("Local selection exceeds K9k’s 1 GiB transfer limit.") }
            try writeHeader(path: archivePath, size: size, directory: false, modified: values.contentModificationDate, to: output)
            let input = try FileHandle(forReadingFrom: url)
            defer { try? input.close() }
            while let data = try input.read(upToCount: 64 * 1024), !data.isEmpty { try output.write(contentsOf: data) }
            let padding = (UInt64(blockSize) - size % UInt64(blockSize)) % UInt64(blockSize)
            if padding > 0 { try output.write(contentsOf: Data(repeating: 0, count: Int(padding))) }
        } else {
            throw PodTransferError("Only regular files and directories can be uploaded: \(url.lastPathComponent)")
        }
    }

    private static func writeHeader(path: String, size: UInt64, directory: Bool, modified: Date?, to output: FileHandle) throws {
        var header = Data(repeating: 0, count: blockSize)
        let (name, prefix) = try splitPath(path)
        put(name, in: &header, offset: 0, length: 100)
        putOctal(0o644, in: &header, offset: 100, length: 8)
        putOctal(0, in: &header, offset: 108, length: 8)
        putOctal(0, in: &header, offset: 116, length: 8)
        putOctal(size, in: &header, offset: 124, length: 12)
        putOctal(UInt64((modified ?? Date()).timeIntervalSince1970), in: &header, offset: 136, length: 12)
        for index in 148..<156 { header[index] = 0x20 }
        header[156] = directory ? 53 : 48
        put("ustar", in: &header, offset: 257, length: 6)
        put("00", in: &header, offset: 263, length: 2)
        put(prefix, in: &header, offset: 345, length: 155)
        let checksum = header.reduce(0) { $0 + UInt($1) }
        putOctal(UInt64(checksum), in: &header, offset: 148, length: 8)
        try output.write(contentsOf: header)
    }

    private static func parseHeader(_ header: Data) throws -> (path: String, size: UInt64, kind: EntryKind) {
        let name = readString(header, offset: 0, length: 100)
        let prefix = readString(header, offset: 345, length: 155)
        let path = prefix.isEmpty ? name : prefix + "/" + name
        guard !path.isEmpty else { throw PodTransferError("Remote archive contains an unnamed entry.") }
        let type = header[156]
        let kind: EntryKind
        switch type { case 0, 48: kind = .file; case 53: kind = .directory; default: throw PodTransferError("Remote archive contains an unsupported link or special file.") }
        return (path, try parseOctal(header, offset: 124, length: 12), kind)
    }

    private enum EntryKind { case file, directory }

    private static func splitPath(_ path: String) throws -> (String, String) {
        let bytes = Array(path.utf8)
        if bytes.count <= 100 { return (path, "") }
        let components = path.split(separator: "/")
        for split in stride(from: components.count - 1, through: 1, by: -1) {
            let prefix = components[..<split].joined(separator: "/")
            let name = components[split...].joined(separator: "/")
            if prefix.utf8.count <= 155 && name.utf8.count <= 100 { return (name, prefix) }
        }
        throw PodTransferError("A selected filename is too long for the safe tar format.")
    }

    private static func validateArchivePath(_ path: String) throws {
        guard !path.hasPrefix("/"), !path.contains("\0"), path.utf8.count <= 255 else { throw PodTransferError("Archive path is invalid.") }
        let parts = path.split(separator: "/", omittingEmptySubsequences: true)
        guard !parts.isEmpty, !parts.contains(where: { $0 == "." || $0 == ".." }) else { throw PodTransferError("Archive path contains traversal.") }
    }

    private static func put(_ value: String, in data: inout Data, offset: Int, length: Int) {
        for (index, byte) in value.utf8.prefix(length).enumerated() { data[offset + index] = byte }
    }

    private static func putOctal(_ value: UInt64, in data: inout Data, offset: Int, length: Int) {
        let text = String(value, radix: 8)
        let padded = String(repeating: "0", count: max(0, length - 1 - text.count)) + text
        put(padded + "\0", in: &data, offset: offset, length: length)
    }

    private static func readString(_ data: Data, offset: Int, length: Int) -> String {
        let bytes = data[offset..<(offset + length)].prefix { $0 != 0 }
        return String(decoding: bytes, as: UTF8.self)
    }

    private static func parseOctal(_ data: Data, offset: Int, length: Int) throws -> UInt64 {
        let text = String(decoding: data[offset..<(offset + length)].prefix { $0 != 0 && $0 != 32 }, as: UTF8.self).trimmingCharacters(in: .whitespaces)
        guard let value = UInt64(text.isEmpty ? "0" : text, radix: 8) else { throw PodTransferError("Remote archive has an invalid size.") }
        return value
    }

    private static func readExactly(_ handle: FileHandle, count: Int) throws -> Data? {
        guard let first = try handle.read(upToCount: count), !first.isEmpty else { return nil }
        var data = first
        while data.count < count {
            guard let next = try handle.read(upToCount: count - data.count), !next.isEmpty else { throw PodTransferError("Remote archive ended unexpectedly.") }
            data.append(next)
        }
        return data
    }

    private static func copy(_ input: FileHandle, to output: FileHandle, count: UInt64) throws {
        var remaining = count
        while remaining > 0 {
            let length = Int(min(remaining, 64 * 1024))
            guard let data = try input.read(upToCount: length), !data.isEmpty else { throw PodTransferError("Remote archive ended unexpectedly.") }
            try output.write(contentsOf: data)
            remaining -= UInt64(data.count)
        }
    }

    private static func skip(_ input: FileHandle, count: UInt64) throws {
        var remaining = count
        while remaining > 0 {
            let length = Int(min(remaining, 64 * 1024))
            guard let data = try input.read(upToCount: length), !data.isEmpty else { throw PodTransferError("Remote archive ended unexpectedly.") }
            remaining -= UInt64(data.count)
        }
    }
}
