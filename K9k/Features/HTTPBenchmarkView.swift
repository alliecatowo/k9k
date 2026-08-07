import AppKit
import Charts
import SwiftUI
import UniformTypeIdentifiers

/// Native equivalent of K9s' `hey`-backed benchmark. It intentionally targets
/// only a K9k-owned loopback forward, keeps a bounded request count, and can
/// be cancelled without touching the Kubernetes workload itself.
struct HTTPBenchmarkView: View {
    @Environment(\.dismiss) private var dismiss
    let forward: ActivePortForward
    let history: BenchmarkHistoryStore
    @State private var path = "/"
    @State private var requests = 200
    @State private var concurrency = 1
    @State private var isRunning = false
    @State private var result: BenchmarkResult?
    @State private var task: Task<Void, Never>?
    @State private var exportError: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("HTTP Benchmark").font(.title2.weight(.semibold))
            Text(forward.binding.endpoint).font(.system(.body, design: .monospaced)).foregroundStyle(.secondary)
            Form {
                TextField("Path", text: $path).disabled(isRunning)
                Stepper("Requests: \(requests)", value: $requests, in: 1...10_000).disabled(isRunning)
                Stepper("Concurrency: \(concurrency)", value: $concurrency, in: 1...min(100, requests)).disabled(isRunning)
            }.formStyle(.grouped)
            if let result {
                resultSummary(result)
            }
            historySummary
            HStack {
                Button("Close") { dismiss() }.disabled(isRunning)
                Spacer()
                if isRunning { Button("Cancel", role: .destructive) { task?.cancel() } }
                else { Button("Run Benchmark") { run() }.keyboardShortcut(.defaultAction) }
            }
        }
        .padding(24)
        .frame(width: 520)
        .onDisappear { task?.cancel() }
        .alert("K9k could not export benchmark history", isPresented: Binding(get: { exportError != nil }, set: { if !$0 { exportError = nil } })) {
            Button("OK", role: .cancel) { exportError = nil }
        } message: { Text(exportError ?? "") }
    }

    private func run() {
        let requested = requests
        let parallelism = min(concurrency, requested)
        guard BenchmarkHistoryStore.isLoopback(forward.binding.localAddress), let url = benchmarkURL() else {
            exportError = "K9k benchmarks only an active loopback port forward."
            return
        }
        isRunning = true; result = nil
        task = Task {
            let start = ContinuousClock.now
            let outcome = await runRequests(url: url, count: requested, concurrency: parallelism)
            guard !Task.isCancelled else { isRunning = false; return }
            let duration = start.duration(to: .now).components
            let elapsed = Double(duration.seconds) + Double(duration.attoseconds) / 1e18
            let finished = BenchmarkResult(requested: requested, completed: outcome.count, successful: outcome.filter { $0.success }.count, elapsed: max(elapsed, 0.001), totalMilliseconds: outcome.reduce(0) { $0 + $1.milliseconds })
            result = finished
            history.record(finished, binding: forward.binding, path: normalizedPath)
            isRunning = false
        }
    }

    private var normalizedPath: String {
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "/" }
        return trimmed.hasPrefix("/") ? trimmed : "/\(trimmed)"
    }

    private func benchmarkURL() -> URL? {
        var components = URLComponents()
        components.scheme = "http"
        components.host = forward.binding.localAddress
        components.port = forward.binding.localPort
        components.path = normalizedPath
        return components.url
    }

    private func runRequests(url: URL, count: Int, concurrency: Int) async -> [RequestOutcome] {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.timeoutIntervalForRequest = 15
        configuration.timeoutIntervalForResource = 15
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        await withTaskGroup(of: RequestOutcome?.self, returning: [RequestOutcome].self) { group in
            var next = 0; var outcomes: [RequestOutcome] = []
            func submit() { group.addTask { guard !Task.isCancelled else { return nil }; let start = ContinuousClock.now; do { let (_, response) = try await session.data(from: url); let duration = start.duration(to: .now); return RequestOutcome(success: (response as? HTTPURLResponse).map { (200...399).contains($0.statusCode) } ?? false, milliseconds: Double(duration.components.seconds) * 1000 + Double(duration.components.attoseconds) / 1e15) } catch { return RequestOutcome(success: false, milliseconds: 0) } } }
            while next < min(count, concurrency) { submit(); next += 1 }
            while let outcome = await group.next() { if let outcome { outcomes.append(outcome) }; if next < count { submit(); next += 1 } }
            return outcomes
        }
    }

    private func resultSummary(_ result: BenchmarkResult) -> some View {
        GroupBox("Latest Result") {
            Grid(alignment: .leading, horizontalSpacing: 22, verticalSpacing: 7) {
                GridRow { Text("Completed"); Text("\(result.completed) / \(result.requested)") }
                GridRow { Text("Successful"); Text("\(result.successful)") }
                GridRow { Text("Failed"); Text("\(result.failed)") }
                GridRow { Text("Rate"); Text(String(format: "%.1f requests/sec", result.requestsPerSecond)) }
                GridRow { Text("Mean latency"); Text(String(format: "%.1f ms", result.meanMilliseconds)) }
                GridRow { Text("Total time"); Text(String(format: "%.2f sec", result.elapsed)) }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    @ViewBuilder private var historySummary: some View {
        if !history.entries.isEmpty {
            GroupBox("This K9k Session") {
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        Text("\(history.entries.count) recent local runs")
                        Spacer()
                        Text(String(format: "Avg %.1f req/sec · %.1f ms", history.averageRate, history.averageLatencyMilliseconds))
                            .foregroundStyle(.secondary)
                    }
                    Chart(history.entries.reversed()) { entry in
                        LineMark(
                            x: .value("Run", entry.recordedAt),
                            y: .value("Requests per second", entry.requestsPerSecond)
                        )
                        .foregroundStyle(.tint)
                        PointMark(
                            x: .value("Run", entry.recordedAt),
                            y: .value("Requests per second", entry.requestsPerSecond)
                        )
                        .foregroundStyle(entry.failed == 0 ? .green : .orange)
                        .accessibilityLabel("\(entry.loopbackEndpoint) \(entry.path), \(String(format: "%.1f", entry.requestsPerSecond)) requests per second")
                    }
                    .chartYAxisLabel("req/sec")
                    .frame(height: 110)
                    HStack {
                        Text("Kept only in memory; export is explicit.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Spacer()
                        Button("Export JSON…") { exportHistory() }
                        Button("Clear", role: .destructive) { history.clear() }
                    }
                }
            }
        }
    }

    private func exportHistory() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "k9k-loopback-benchmark-history.json"
        panel.allowedContentTypes = [.json]
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try history.exportData().write(to: url, options: .atomic)
        } catch {
            exportError = error.localizedDescription
        }
    }
}

private struct RequestOutcome { let success: Bool; let milliseconds: Double }
