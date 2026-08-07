import SwiftUI

/// Native equivalent of K9s' `hey`-backed benchmark. It intentionally targets
/// only a K9k-owned loopback forward, keeps a bounded request count, and can
/// be cancelled without touching the Kubernetes workload itself.
struct HTTPBenchmarkView: View {
    @Environment(\.dismiss) private var dismiss
    let forward: ActivePortForward
    @State private var path = "/"
    @State private var requests = 200
    @State private var concurrency = 1
    @State private var isRunning = false
    @State private var result: BenchmarkResult?
    @State private var task: Task<Void, Never>?

    private var baseURL: URL { URL(string: "http://\(forward.binding.localAddress):\(forward.binding.localPort)")! }

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
                GroupBox("Result") {
                    Grid(alignment: .leading, horizontalSpacing: 22, verticalSpacing: 7) {
                        GridRow { Text("Completed"); Text("\(result.completed) / \(result.requested)") }
                        GridRow { Text("Successful"); Text("\(result.successful)") }
                        GridRow { Text("Failed"); Text("\(result.failed)") }
                        GridRow { Text("Rate"); Text(String(format: "%.1f requests/sec", result.requestsPerSecond)) }
                        GridRow { Text("Mean latency"); Text(String(format: "%.1f ms", result.meanMilliseconds)) }
                        GridRow { Text("Total time"); Text(String(format: "%.2f sec", result.elapsed)) }
                    }.frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            HStack {
                Button("Close") { dismiss() }.disabled(isRunning)
                Spacer()
                if isRunning { Button("Cancel", role: .destructive) { task?.cancel() } }
                else { Button("Run Benchmark") { run() }.keyboardShortcut(.defaultAction) }
            }
        }.padding(24).frame(width: 480)
        .onDisappear { task?.cancel() }
    }

    private func run() {
        let requested = requests
        let parallelism = min(concurrency, requested)
        let url = URL(string: path, relativeTo: baseURL)!
        isRunning = true; result = nil
        task = Task {
            let start = ContinuousClock.now
            let outcome = await runRequests(url: url, count: requested, concurrency: parallelism)
            guard !Task.isCancelled else { isRunning = false; return }
            let duration = start.duration(to: .now).components
            let elapsed = Double(duration.seconds) + Double(duration.attoseconds) / 1e18
            result = BenchmarkResult(requested: requested, completed: outcome.count, successful: outcome.filter { $0.success }.count, elapsed: max(elapsed, 0.001), totalMilliseconds: outcome.reduce(0) { $0 + $1.milliseconds })
            isRunning = false
        }
    }

    private func runRequests(url: URL, count: Int, concurrency: Int) async -> [RequestOutcome] {
        await withTaskGroup(of: RequestOutcome?.self, returning: [RequestOutcome].self) { group in
            var next = 0; var outcomes: [RequestOutcome] = []
            func submit() { group.addTask { guard !Task.isCancelled else { return nil }; let start = ContinuousClock.now; do { let (_, response) = try await URLSession.shared.data(from: url); let duration = start.duration(to: .now); return RequestOutcome(success: (response as? HTTPURLResponse).map { (200...399).contains($0.statusCode) } ?? false, milliseconds: Double(duration.components.seconds) * 1000 + Double(duration.components.attoseconds) / 1e15) } catch { return RequestOutcome(success: false, milliseconds: 0) } } }
            while next < min(count, concurrency) { submit(); next += 1 }
            while let outcome = await group.next() { if let outcome { outcomes.append(outcome) }; if next < count { submit(); next += 1 } }
            return outcomes
        }
    }
}

private struct RequestOutcome { let success: Bool; let milliseconds: Double }
private struct BenchmarkResult { let requested: Int; let completed: Int; let successful: Int; let elapsed: Double; let totalMilliseconds: Double; var failed: Int { completed - successful }; var requestsPerSecond: Double { Double(completed) / elapsed }; var meanMilliseconds: Double { completed == 0 ? 0 : totalMilliseconds / Double(completed) } }
