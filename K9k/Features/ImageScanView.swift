import Foundation
import SwiftUI

/// A deliberately opt-in adapter for locally installed image scanners. K9k
/// does not ship a scanner (unlike K9s' embedded Grype path), invoke a shell,
/// inherit cloud/Kubernetes credentials, or run a scan automatically.
struct ImageScanView: View {
    @Environment(\.dismiss) private var dismiss
    let resource: ResourceSummary

    @State private var selectedImageIDs = Set<ImageScanTarget.ID>()
    @State private var confirmationPresented = false
    @State private var isRunning = false
    @State private var isCancelling = false
    @State private var output = ""
    @State private var normalizedReports: [ImageScanNormalizedReport] = []
    @State private var showingNormalizedResults = true
    @State private var currentImage: String?
    @State private var operation: ImageScanOperation?

    private var targets: [ImageScanTarget] { Self.targets(for: resource) }
    private var configuration: ImageScanConfiguration { ImageScanPreferences.load() }
    private var selectedTargets: [ImageScanTarget] { targets.filter { selectedImageIDs.contains($0.id) } }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                if resource.raw == nil {
                    ContentUnavailableView("Loading Resource Images", systemImage: "shippingbox", description: Text("K9k needs the selected resource's live manifest before it can extract image references."))
                } else if targets.isEmpty {
                    ContentUnavailableView("No Container Images", systemImage: "shippingbox", description: Text("The selected resource does not declare Pod or workload-template container images."))
                } else {
                    Form {
                        Section("Target") {
                            LabeledContent("Resource", value: "\(resource.kind) / \(resource.name)")
                            LabeledContent("Namespace", value: resource.namespace ?? "Cluster-scoped")
                        }

                        Section("Image references") {
                            ForEach(targets) { target in
                                Toggle(isOn: Binding(
                                    get: { selectedImageIDs.contains(target.id) },
                                    set: { enabled in
                                        if enabled { selectedImageIDs.insert(target.id) }
                                        else { selectedImageIDs.remove(target.id) }
                                    }
                                )) {
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(target.image).font(.system(.body, design: .monospaced))
                                        Text(target.locations.joined(separator: " · ")).font(.caption).foregroundStyle(.secondary)
                                    }
                                }
                                .disabled(isRunning)
                            }
                        }

                        Section("Configured scanner") {
                            if let validationMessage = configuration.validationMessage() {
                                Label(validationMessage, systemImage: "exclamationmark.triangle")
                                    .foregroundStyle(.orange)
                                Text("Set an absolute scanner path and one argument per line in Settings. Include \(ImageScanConfiguration.imagePlaceholder) where the image reference belongs. K9k never downloads or chooses a scanner for you.")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            } else {
                                LabeledContent("Executable", value: configuration.executablePath)
                                LabeledContent("Arguments", value: "\(configuration.arguments.count) configured")
                                Text("K9k runs this exact non-shell process only after confirmation. It passes the selected image reference as an argument and gives the scanner a minimal environment without Kubernetes or cloud credential variables.")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                    .formStyle(.grouped)
                }

                Divider()
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text(showingNormalizedResults && configuration.reportFormat == .grypeJSON ? "Vulnerability findings" : "Scanner output").font(.headline)
                        Spacer()
                        if let currentImage { Text(currentImage).font(.caption).foregroundStyle(.secondary).lineLimit(1) }
                    }
                    if configuration.reportFormat == .grypeJSON, !normalizedReports.isEmpty {
                        Picker("Result presentation", selection: $showingNormalizedResults) {
                            Text("Findings").tag(true)
                            Text("Raw Output").tag(false)
                        }
                        .pickerStyle(.segmented)
                        .labelsHidden()
                    }
                    if showingNormalizedResults, configuration.reportFormat == .grypeJSON, !normalizedReports.isEmpty {
                        ImageScanFindingsView(reports: normalizedReports)
                    } else {
                        ScrollView {
                            Text(output.isEmpty ? "Output is shown only after you explicitly run a configured scanner." : output)
                                .font(.system(.caption, design: .monospaced))
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                }
                .padding()
                .frame(minHeight: 180, maxHeight: 260)
            }
            .navigationTitle("Image Scan")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { dismiss() }.disabled(isRunning)
                }
                ToolbarItem(placement: .confirmationAction) {
                    if isRunning {
                        Button(isCancelling ? "Cancelling…" : "Stop", role: .destructive) { stop() }
                            .disabled(isCancelling)
                    } else {
                        Button("Scan Selected…") { confirmationPresented = true }
                            .disabled(selectedTargets.isEmpty || configuration.validationMessage() != nil)
                    }
                }
            }
        }
        .frame(minWidth: 760, minHeight: 600)
        .onAppear { selectedImageIDs = Set(targets.map(\.id)) }
        .onDisappear { operation?.cancel() }
        .confirmationDialog("Run configured image scanner?", isPresented: $confirmationPresented, titleVisibility: .visible) {
            Button("Scan \(selectedTargets.count) Image\(selectedTargets.count == 1 ? "" : "s")") { start() }
        } message: {
            Text(confirmationMessage)
        }
    }

    private var confirmationMessage: String {
        let preview = selectedTargets.prefix(4).map(\.image).joined(separator: "\n")
        let remaining = selectedTargets.count > 4 ? "\n… and \(selectedTargets.count - 4) more" : ""
        return "K9k will run this exact local process once per selected image:\n\n\(configuration.executablePath)\n\(configuration.arguments.joined(separator: "\n"))\n\nImages:\n\(preview)\(remaining)\n\nThe scanner may read its own cache or contact registries. K9k does not pass kubeconfig, cloud tokens, or inherited shell environment variables. Output is capped at 512 KiB per image and redacted before display."
    }

    private func start() {
        guard configuration.validationMessage() == nil, !selectedTargets.isEmpty else { return }
        let configuration = configuration
        let selectedTargets = selectedTargets
        let operation = ImageScanOperation()
        self.operation = operation
        output = ""
        normalizedReports = []
        showingNormalizedResults = configuration.reportFormat == .grypeJSON
        currentImage = nil
        isRunning = true
        isCancelling = false

        DispatchQueue.global(qos: .userInitiated).async {
            var report = ""
            for target in selectedTargets {
                if operation.isCancelled { break }
                DispatchQueue.main.async { currentImage = target.image }
                let result = operation.run(configuration: configuration, image: target.image)
                let normalized = configuration.reportFormat == .grypeJSON
                    ? ImageScanReportNormalizer.normalizeGrypeJSON(result.output, image: target.image)
                    : nil
                let heading = "\n$ \(configuration.executablePath) \(configuration.expandedArguments(for: target.image).joined(separator: " "))\n"
                report += heading + result.renderedOutput + "\n\(result.status)\n"
                let visibleReport = ImageScanOutputRedactor.redact(report)
                DispatchQueue.main.async {
                    output = visibleReport
                    if let normalized {
                        normalizedReports.removeAll { $0.image == normalized.image }
                        normalizedReports.append(normalized)
                    }
                }
            }
            DispatchQueue.main.async {
                if operation.isCancelled && report.isEmpty { output = "Scan cancelled before a scanner process started." }
                isRunning = false
                isCancelling = false
                currentImage = nil
                self.operation = nil
            }
        }
    }

    private func stop() {
        isCancelling = true
        operation?.cancel()
    }

    private static func targets(for resource: ResourceSummary) -> [ImageScanTarget] {
        guard let object = resource.raw?.objectValue else { return [] }
        let directSpec = object["spec"]?.objectValue
        let specs: [(String, [String: JSONValue]?)] = [
            ("Pod", directSpec),
            ("Workload template", directSpec?["template"]?.objectValue?["spec"]?.objectValue),
            ("CronJob template", directSpec?["jobTemplate"]?.objectValue?["spec"]?.objectValue?["template"]?.objectValue?["spec"]?.objectValue),
        ]
        var locationsByImage: [String: [String]] = [:]
        var orderedImages: [String] = []
        for (source, spec) in specs {
            guard let spec else { continue }
            for (field, title) in [("containers", "Container"), ("initContainers", "Init container"), ("ephemeralContainers", "Ephemeral container")] {
                for container in spec[field]?.arrayValue ?? [] {
                    guard let container = container.objectValue,
                          let image = container["image"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines),
                          !image.isEmpty else { continue }
                    if locationsByImage[image] == nil { orderedImages.append(image) }
                    let name = container["name"]?.stringValue ?? "unnamed"
                    locationsByImage[image, default: []].append("\(source) · \(title): \(name)")
                }
            }
        }
        return orderedImages.map { ImageScanTarget(image: $0, locations: locationsByImage[$0] ?? []) }
    }
}

/// The settings UI is intentionally separate from the K9s config editor:
/// K9s' `imageScans` config only enables its embedded scanner and exclusions,
/// while this adapter never assumes a scanner installation or credentials.
struct ImageScanSettingsSection: View {
    @State private var configuration = ImageScanPreferences.load()

    var body: some View {
        Section("Image scanner (optional)") {
            TextField("Scanner executable", text: $configuration.executablePath, prompt: Text("/opt/homebrew/bin/grype"))
                .textFieldStyle(.roundedBorder)
            VStack(alignment: .leading, spacing: 6) {
                Text("Arguments template (one argument per line)")
                TextEditor(text: $configuration.argumentTemplate)
                    .font(.system(.body, design: .monospaced))
                    .frame(minHeight: 72)
                    .overlay { RoundedRectangle(cornerRadius: 6).stroke(.quaternary) }
                Text("Use \(ImageScanConfiguration.imagePlaceholder) for the image reference. Example for Grype: \(ImageScanConfiguration.imagePlaceholder). Example for Trivy: `image`, then \(ImageScanConfiguration.imagePlaceholder). Arguments are never passed through a shell.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Picker("Normalized report", selection: $configuration.reportFormat) {
                ForEach(ImageScanReportFormat.allCases) { format in Text(format.title).tag(format) }
            }
            if configuration.reportFormat == .grypeJSON {
                Text("K9k will parse only valid Grype JSON into CVE/package/severity/fix fields. Configure Grype's JSON output yourself (for example, separate arguments `-o` and `json`); K9k does not alter or infer scanner arguments.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if let message = configuration.validationMessage() {
                Label(message, systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.orange)
            } else {
                Label("Configured local scanner", systemImage: "checkmark.circle")
                    .font(.caption)
                    .foregroundStyle(.green)
            }
            Text("K9k stores only the executable path and argument template. Inline credentials are rejected; configure credentials in the scanner's Keychain or its own configuration. Each scan requires a separate confirmation and receives a minimal environment with no inherited Kubernetes or cloud credential variables.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .onChange(of: configuration) { _, updated in ImageScanPreferences.save(updated) }
        .onAppear { configuration = ImageScanPreferences.load() }
    }
}

private struct ImageScanFindingsView: View {
    let reports: [ImageScanNormalizedReport]

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(reports.sorted { $0.image.localizedStandardCompare($1.image) == .orderedAscending }) { report in
                    VStack(alignment: .leading, spacing: 5) {
                        Text(report.image)
                            .font(.system(.caption, design: .monospaced))
                            .foregroundStyle(.secondary)
                        if let diagnostic = report.diagnostic {
                            Label(diagnostic, systemImage: "exclamationmark.triangle")
                                .font(.caption)
                                .foregroundStyle(.orange)
                        } else if report.findings.isEmpty {
                            Label("No vulnerabilities reported", systemImage: "checkmark.circle")
                                .font(.caption)
                                .foregroundStyle(.green)
                        } else {
                            ForEach(report.findings.sorted { lhs, rhs in
                                if lhs.severityRank != rhs.severityRank { return lhs.severityRank < rhs.severityRank }
                                return lhs.vulnerabilityID.localizedStandardCompare(rhs.vulnerabilityID) == .orderedAscending
                            }) { finding in
                                HStack(alignment: .firstTextBaseline, spacing: 10) {
                                    Text(finding.severity.uppercased())
                                        .font(.caption.weight(.semibold))
                                        .foregroundStyle(severityColor(finding.severity))
                                        .frame(width: 64, alignment: .leading)
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(finding.vulnerabilityID).font(.system(.caption, design: .monospaced))
                                        Text("\(finding.package) \(finding.installedVersion)")
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    }
                                    Spacer(minLength: 8)
                                    if let fixedIn = finding.fixedIn, !fixedIn.isEmpty {
                                        Text("Fix: \(fixedIn)")
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                            .lineLimit(1)
                                    }
                                }
                                .padding(.vertical, 3)
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 8)
                    Divider()
                }
            }
        }
    }

    private func severityColor(_ severity: String) -> Color {
        switch severity.uppercased() {
        case "CRITICAL": .red
        case "HIGH": .orange
        case "MEDIUM", "MODERATE": .yellow
        case "LOW": .blue
        case "NEGLIGIBLE": .secondary
        default: .secondary
        }
    }
}

private final class ImageScanOperation: @unchecked Sendable {
    private let lock = NSLock()
    private var process: Process?
    private var cancelled = false

    var isCancelled: Bool {
        lock.lock(); defer { lock.unlock() }
        return cancelled
    }

    func cancel() {
        lock.lock()
        cancelled = true
        let process = process
        lock.unlock()
        process?.terminate()
    }

    func run(configuration: ImageScanConfiguration, image: String) -> ImageScanRunResult {
        if isCancelled { return ImageScanRunResult(output: "", status: "Cancelled.") }
        let process = Process()
        let pipe = Pipe()
        let collector = ImageScanOutputCollector(limit: 512 * 1024)
        process.executableURL = URL(fileURLWithPath: configuration.executablePath.trimmingCharacters(in: .whitespacesAndNewlines))
        process.arguments = configuration.expandedArguments(for: image)
        process.standardOutput = pipe
        process.standardError = pipe
        process.environment = minimalEnvironment()
        pipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if !data.isEmpty { collector.append(data) }
        }

        lock.lock()
        if cancelled { lock.unlock(); pipe.fileHandleForReading.readabilityHandler = nil; return ImageScanRunResult(output: "", status: "Cancelled.") }
        self.process = process
        lock.unlock()

        let timeoutState = ImageScanTimeoutState()
        let timeout = DispatchWorkItem { [weak self, weak process] in
            guard let self, let process else { return }
            self.lock.lock()
            let shouldTerminate = self.process === process && !self.cancelled
            self.lock.unlock()
            if shouldTerminate { timeoutState.markTimedOut(); process.terminate() }
        }

        do {
            try process.run()
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 120, execute: timeout)
            process.waitUntilExit()
        } catch {
            timeout.cancel()
            pipe.fileHandleForReading.readabilityHandler = nil
            clear(process)
            return ImageScanRunResult(output: "", status: "Could not start scanner: \(error.localizedDescription)")
        }
        timeout.cancel()
        pipe.fileHandleForReading.readabilityHandler = nil
        let trailingOutput = pipe.fileHandleForReading.availableData
        if !trailingOutput.isEmpty { collector.append(trailingOutput) }
        clear(process)
        let suffix: String
        if isCancelled { suffix = "Cancelled." }
        else if timeoutState.didTimeOut { suffix = "Stopped after the 120-second per-image limit." }
        else if process.terminationStatus == 0 { suffix = "Completed successfully." }
        else { suffix = "Exited with status \(process.terminationStatus)." }
        return ImageScanRunResult(output: collector.text, status: suffix + (collector.hasTruncated ? " Output was truncated at 512 KiB." : ""))
    }

    private func clear(_ completed: Process) {
        lock.lock()
        if process === completed { process = nil }
        lock.unlock()
    }

    private func minimalEnvironment() -> [String: String] {
        var environment = [
            "PATH": "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin",
            "HOME": NSHomeDirectory(),
            "TMPDIR": NSTemporaryDirectory(),
            "LANG": ProcessInfo.processInfo.environment["LANG"] ?? "en_US.UTF-8",
        ]
        if let locale = ProcessInfo.processInfo.environment["LC_ALL"] { environment["LC_ALL"] = locale }
        return environment
    }
}

private struct ImageScanRunResult {
    let output: String
    let status: String
    var renderedOutput: String { output.isEmpty ? "(Scanner produced no output.)" : output }
}

private final class ImageScanOutputCollector: @unchecked Sendable {
    private let limit: Int
    private let lock = NSLock()
    private var data = Data()
    private var didTruncate = false

    init(limit: Int) { self.limit = limit }

    func append(_ chunk: Data) {
        lock.lock(); defer { lock.unlock() }
        guard !didTruncate else { return }
        let capacity = limit - data.count
        if capacity <= 0 { didTruncate = true; return }
        data.append(chunk.prefix(capacity))
        if chunk.count > capacity { didTruncate = true }
    }

    var text: String {
        lock.lock(); defer { lock.unlock() }
        return String(decoding: data, as: UTF8.self)
    }

    var hasTruncated: Bool {
        lock.lock(); defer { lock.unlock() }
        return didTruncate
    }
}

private final class ImageScanTimeoutState: @unchecked Sendable {
    private let lock = NSLock()
    private var timedOut = false

    func markTimedOut() {
        lock.lock(); defer { lock.unlock() }
        timedOut = true
    }

    var didTimeOut: Bool {
        lock.lock(); defer { lock.unlock() }
        return timedOut
    }
}

private enum ImageScanOutputRedactor {
    static func redact(_ value: String) -> String {
        var result = value
        let patterns = [
            #"(?i)(authorization\s*[:=]\s*(?:bearer\s+)?)[^\s]+"#,
            #"(?i)((?:token|password|secret|api[-_]?key)\s*[:=]\s*)[^\s,;]+"#,
            #"(?i)(https?://)[^/@\s]+@"#,
        ]
        for pattern in patterns {
            result = result.replacingOccurrences(of: pattern, with: "$1<redacted>", options: .regularExpression)
        }
        return result
    }
}
