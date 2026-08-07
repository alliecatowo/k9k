import Charts
import SwiftUI

/// A compact native counterpart to K9s Pulse. It polls only metrics-server's
/// standard pod/node collections and retains a bounded in-memory history;
/// opening it never changes a Kubernetes resource.
struct PulseView: View {
    @Environment(ClusterStore.self) private var store
    @Binding var isPresented: Bool
    @State private var history: [PulsePoint] = []
    @State private var samplingTask: Task<Void, Never>?

    var body: some View {
        NavigationStack {
            Group {
                if let message = store.pulseMetricsUnavailableMessage {
                    ContentUnavailableView("Metrics Unavailable", systemImage: "waveform.path.ecg", description: Text(message))
                } else if store.isLoadingPulseMetrics && history.isEmpty {
                    ProgressView("Loading cluster usage…")
                } else if history.isEmpty {
                    ContentUnavailableView("No Pulse Samples", systemImage: "waveform.path.ecg", description: Text("Metrics Server did not return a sample yet."))
                } else {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 20) {
                            HStack(spacing: 12) {
                                PulseStat(title: "Nodes", value: "\(store.pulseNodeMetrics.count)", detail: "CPU \(current.cpuMilli.formatted(.number.precision(.fractionLength(0))))m · Memory \(current.memoryMi.formatted(.number.precision(.fractionLength(0)))) Mi")
                                PulseStat(title: "Pods", value: "\(store.pulsePodMetrics.count)", detail: "sampled across all namespaces")
                            }
                            GroupBox("Cluster CPU") {
                                Chart(history) { point in
                                    LineMark(x: .value("Time", point.date), y: .value("CPU (m)", point.cpuMilli))
                                        .foregroundStyle(.blue)
                                    AreaMark(x: .value("Time", point.date), y: .value("CPU (m)", point.cpuMilli))
                                        .foregroundStyle(.blue.opacity(0.16))
                                }
                                .chartYAxisLabel("millicores")
                                .frame(height: 170)
                            }
                            GroupBox("Cluster Memory") {
                                Chart(history) { point in
                                    LineMark(x: .value("Time", point.date), y: .value("Memory (Mi)", point.memoryMi))
                                        .foregroundStyle(.purple)
                                    AreaMark(x: .value("Time", point.date), y: .value("Memory (Mi)", point.memoryMi))
                                        .foregroundStyle(.purple.opacity(0.16))
                                }
                                .chartYAxisLabel("MiB")
                                .frame(height: 170)
                            }
                            Text("Updates every 5 seconds while this window is open. Values aggregate Metrics Server node usage; they are observational only.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        .padding()
                    }
                }
            }
            .navigationTitle("Pulse")
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button { Task { await sample() } } label: { Label("Refresh Pulse", systemImage: "arrow.clockwise") }
                }
                ToolbarItem(placement: .cancellationAction) { Button("Close") { isPresented = false } }
            }
        }
        .frame(minWidth: 620, minHeight: 480)
        .task { startSampling() }
        .onDisappear { samplingTask?.cancel() }
    }

    private var current: PulsePoint { history.last ?? .init(date: .now, cpuMilli: 0, memoryMi: 0) }

    private func startSampling() {
        samplingTask?.cancel()
        samplingTask = Task {
            while !Task.isCancelled {
                await sample()
                try? await Task.sleep(for: .seconds(5))
            }
        }
    }

    private func sample() async {
        await store.loadPulseMetrics()
        guard store.pulseMetricsUnavailableMessage == nil else { return }
        let point = PulsePoint(date: .now, cpuMilli: store.pulseNodeMetrics.reduce(0) { $0 + quantityMilli($1.usage["cpu"]) }, memoryMi: store.pulseNodeMetrics.reduce(0) { $0 + quantityMi($1.usage["memory"]) })
        history = Array((history + [point]).suffix(60))
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

private struct PulsePoint: Identifiable {
    let date: Date
    let cpuMilli: Double
    let memoryMi: Double
    var id: Date { date }
}

private struct PulseStat: View {
    let title: String
    let value: String
    let detail: String

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Text(value).font(.title2.weight(.semibold)).monospacedDigit()
            Text(detail).font(.caption).foregroundStyle(.secondary).lineLimit(2)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(.quaternary, in: .rect(cornerRadius: 10))
    }
}
