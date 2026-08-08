import Charts
import SwiftUI

/// A compact native counterpart to K9s Pulse. It uses exactly two direct
/// metrics collections per sample, never mutates the cluster, and retains at
/// most five minutes of session-local history at a five-second cadence.
struct PulseView: View {
    private static let sampleInterval: Duration = .seconds(5)
    private static let maximumSamples = 60

    @Environment(ClusterStore.self) private var store
    @Binding var isPresented: Bool
    let drilldownTarget: PulseDrilldownTarget?
    @State private var history: [PulseHistorySample] = []
    @State private var samplingTask: Task<Void, Never>?

    var body: some View {
        NavigationStack {
            Group {
                if !store.hasUsablePulseMetrics && history.isEmpty, let message = store.pulseMetricsUnavailableMessage {
                    ContentUnavailableView("Metrics Unavailable", systemImage: "waveform.path.ecg", description: Text(message))
                } else if store.isLoadingPulseMetrics && history.isEmpty && store.pulseMetricsDiagnostics.isEmpty {
                    ProgressView("Loading cluster usage…")
                } else if history.isEmpty && !store.hasUsablePulseMetrics {
                    ContentUnavailableView("No Pulse Samples", systemImage: "waveform.path.ecg", description: Text("Metrics Server did not return a sample yet."))
                } else {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 18) {
                            diagnostics
                            summary
                            if let drilldownTarget { drilldown(drilldownTarget) }
                            charts
                            Text("Updates every 5 seconds while this window is open. History stays in memory, is capped at 60 samples, and is never written unless you export it.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        .padding()
                    }
                }
            }
            .navigationTitle(drilldownTarget.map { "Pulse · \($0.name)" } ?? "Pulse")
            .toolbar {
                ToolbarItemGroup(placement: .primaryAction) {
                    Button { Task { await sample() } } label: { Label("Refresh Pulse", systemImage: "arrow.clockwise") }
                        .disabled(store.isLoadingPulseMetrics)
                        .help("Refresh the node and pod metrics once")
                    Menu("Export") {
                        Button("Save History as JSON…") { saveHistory(as: .json) }
                            .disabled(history.isEmpty)
                        Button("Save History as CSV…") { saveHistory(as: .csv) }
                            .disabled(history.isEmpty)
                        Divider()
                        Button("Save Current Window as PNG…") { saveScreenshot() }
                    }
                }
                ToolbarItem(placement: .cancellationAction) { Button("Close") { isPresented = false } }
            }
        }
        .frame(minWidth: 680, minHeight: 540)
        .task { startSampling() }
        .onDisappear { samplingTask?.cancel() }
    }

    @ViewBuilder private var diagnostics: some View {
        if !store.pulseMetricsDiagnostics.isEmpty {
            GroupBox("Metric Sources") {
                Grid(alignment: .leading, horizontalSpacing: 18, verticalSpacing: 8) {
                    ForEach(store.pulseMetricsDiagnostics) { diagnostic in
                        GridRow {
                            Label(diagnostic.title, systemImage: symbol(for: diagnostic.state))
                                .foregroundStyle(color(for: diagnostic.state))
                            Text(diagnostic.state.displayName)
                                .foregroundStyle(.secondary)
                            Text(diagnostic.state == .available ? "\(diagnostic.itemCount) reported" : (diagnostic.message ?? "No detail returned"))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .textSelection(.enabled)
                        }
                    }
                }
                if store.pulseMetricsDiagnostics.contains(where: { $0.state != .available }) && store.hasUsablePulseMetrics {
                    Text("Partial sample: unavailable sources are excluded rather than treated as zero.")
                        .font(.caption)
                        .foregroundStyle(.orange)
                        .padding(.top, 8)
                }
            }
        }
    }

    private var summary: some View {
        GroupBox("Cluster Sample") {
            Grid(alignment: .leading, horizontalSpacing: 24, verticalSpacing: 8) {
                GridRow {
                    LabeledContent("Nodes", value: "\(store.pulseNodeMetrics.count)")
                    LabeledContent("Pods", value: "\(store.pulsePodMetrics.count)")
                }
                GridRow {
                    LabeledContent("CPU", value: current.cpuMilli.formatted(.number.precision(.fractionLength(0))) + "m")
                    LabeledContent("Memory", value: current.memoryMi.formatted(.number.precision(.fractionLength(0))) + " MiB")
                }
                if let last = history.last {
                    GridRow {
                        LabeledContent("Node sample", value: last.timestamp.formatted(date: .omitted, time: .standard))
                        LabeledContent("History", value: "\(history.count) / \(Self.maximumSamples)")
                    }
                }
            }
        }
    }

    @ViewBuilder private func drilldown(_ target: PulseDrilldownTarget) -> some View {
        GroupBox("Selected \(target.kind)") {
            if let metric = drilldownMetric(for: target) {
                Grid(alignment: .leading, horizontalSpacing: 24, verticalSpacing: 8) {
                    GridRow {
                        LabeledContent("Name", value: metric.name)
                        LabeledContent("Namespace", value: metric.namespace ?? "Cluster-scoped")
                    }
                    GridRow {
                        LabeledContent("CPU", value: metric.usage["cpu"] ?? "—")
                        LabeledContent("Memory", value: metric.usage["memory"] ?? "—")
                    }
                    GridRow {
                        LabeledContent("Sample", value: metric.timestamp.formatted(date: .omitted, time: .standard))
                        LabeledContent("Window", value: metric.window.isEmpty ? "—" : metric.window)
                    }
                }
                if !metric.containers.isEmpty {
                    Divider().padding(.vertical, 4)
                    ForEach(metric.containers) { container in
                        LabeledContent(container.name, value: "CPU \(container.usage["cpu"] ?? "—") · Memory \(container.usage["memory"] ?? "—")")
                    }
                }
            } else {
                Text("This resource was not included in the latest available \(target.metricResource) metric collection.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder private var charts: some View {
        if history.isEmpty {
            ContentUnavailableView("No Node History", systemImage: "chart.xyaxis.line", description: Text("Node metrics are unavailable or have not produced a sample yet."))
        } else {
            GroupBox("Cluster CPU") {
                Chart(history) { point in
                    LineMark(x: .value("Time", point.timestamp), y: .value("CPU (m)", point.cpuMilli))
                        .foregroundStyle(.blue)
                    AreaMark(x: .value("Time", point.timestamp), y: .value("CPU (m)", point.cpuMilli))
                        .foregroundStyle(.blue.opacity(0.16))
                }
                .chartYAxisLabel("millicores")
                .frame(height: 170)
            }
            GroupBox("Cluster Memory") {
                Chart(history) { point in
                    LineMark(x: .value("Time", point.timestamp), y: .value("Memory (Mi)", point.memoryMi))
                        .foregroundStyle(.purple)
                    AreaMark(x: .value("Time", point.timestamp), y: .value("Memory (Mi)", point.memoryMi))
                        .foregroundStyle(.purple.opacity(0.16))
                }
                .chartYAxisLabel("MiB")
                .frame(height: 170)
            }
        }
    }

    private var current: PulseHistorySample {
        history.last ?? PulseHistorySample(timestamp: .now, cpuMilli: 0, memoryMi: 0, nodeCount: store.pulseNodeMetrics.count, podCount: store.pulsePodMetrics.count)
    }

    private func startSampling() {
        samplingTask?.cancel()
        samplingTask = Task {
            while !Task.isCancelled {
                await sample()
                try? await Task.sleep(for: Self.sampleInterval)
            }
        }
    }

    private func sample() async {
        await store.loadPulseMetrics()
        guard !Task.isCancelled,
              store.pulseMetricsDiagnostics.first(where: { $0.resource == "nodes" })?.state == .available
        else { return }
        let point = PulseHistorySample(
            timestamp: .now,
            cpuMilli: store.pulseNodeMetrics.reduce(0) { $0 + quantityMilli($1.usage["cpu"]) },
            memoryMi: store.pulseNodeMetrics.reduce(0) { $0 + quantityMi($1.usage["memory"]) },
            nodeCount: store.pulseNodeMetrics.count,
            podCount: store.pulsePodMetrics.count
        )
        history = Array((history + [point]).suffix(Self.maximumSamples))
    }

    private func drilldownMetric(for target: PulseDrilldownTarget) -> ResourceMetrics? {
        let source = target.metricResource == "pods" ? store.pulsePodMetrics : store.pulseNodeMetrics
        return source.first { $0.name == target.name && $0.namespace == target.namespace }
    }

    private func saveHistory(as format: PulseHistoryExporter.Format) {
        let snapshot = PulseHistoryExport(
            schemaVersion: 1, exportedAt: .now, context: store.selectedContext?.name,
            sampleIntervalSeconds: 5, maximumSamples: Self.maximumSamples,
            diagnostics: store.pulseMetricsDiagnostics, samples: history
        )
        do {
            try PulseHistoryExporter.save(snapshot, as: format, defaultName: "k9k-pulse-\(safeFilenameComponent(store.selectedContext?.name ?? "cluster"))")
        } catch {
            store.errorMessage = "K9k could not save the Pulse export: \(error.localizedDescription)"
        }
    }

    private func saveScreenshot() {
        Task {
            do {
                try await WindowScreenshotExporter.saveCurrentWindow(named: "k9k-pulse-window.png")
            } catch {
                store.errorMessage = "K9k could not save the Pulse screenshot: \(error.localizedDescription)"
            }
        }
    }

    private func symbol(for state: MetricsCollectionState) -> String {
        switch state {
        case .available: "checkmark.circle.fill"
        case .unavailable: "exclamationmark.triangle.fill"
        case .failed: "xmark.octagon.fill"
        }
    }

    private func color(for state: MetricsCollectionState) -> Color {
        switch state {
        case .available: .green
        case .unavailable: .orange
        case .failed: .red
        }
    }

    private func safeFilenameComponent(_ value: String) -> String {
        let invalid = CharacterSet(charactersIn: "/:\\")
        let sanitized = value.components(separatedBy: invalid).joined(separator: "-")
        return sanitized.isEmpty ? "cluster" : sanitized
    }

    private func quantityMilli(_ value: String?) -> Double {
        guard let value else { return 0 }
        if value.hasSuffix("m") { return Double(value.dropLast()) ?? 0 }
        if value.hasSuffix("n") { return (Double(value.dropLast()) ?? 0) / 1_000_000 }
        if value.hasSuffix("u") { return (Double(value.dropLast()) ?? 0) / 1_000 }
        return (Double(value) ?? 0) * 1_000
    }

    private func quantityMi(_ value: String?) -> Double {
        guard let value else { return 0 }
        let units: [(String, Double)] = [("Ki", 1.0 / 1_024), ("Mi", 1), ("Gi", 1_024), ("Ti", 1_048_576)]
        for (suffix, multiplier) in units where value.hasSuffix(suffix) {
            return (Double(value.dropLast(suffix.count)) ?? 0) * multiplier
        }
        return (Double(value) ?? 0) / 1_048_576
    }
}
