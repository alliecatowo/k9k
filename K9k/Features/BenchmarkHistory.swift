import Foundation
import Observation

struct BenchmarkResult: Hashable {
    let requested: Int
    let completed: Int
    let successful: Int
    let elapsed: Double
    let totalMilliseconds: Double

    var failed: Int { completed - successful }
    var requestsPerSecond: Double { Double(completed) / max(elapsed, 0.001) }
    var meanMilliseconds: Double { completed == 0 ? 0 : totalMilliseconds / Double(completed) }
}

/// Session-only record of benchmark summaries. It deliberately holds no
/// response body, headers, credentials, Kubernetes object identity, or remote
/// address. A history item can only originate from a K9k loopback forward.
@MainActor
@Observable
final class BenchmarkHistoryStore {
    static let maximumEntries = 32

    private(set) var entries: [BenchmarkHistoryEntry] = []

    var averageRate: Double {
        guard !entries.isEmpty else { return 0 }
        return entries.map(\.requestsPerSecond).reduce(0, +) / Double(entries.count)
    }

    var averageLatencyMilliseconds: Double {
        guard !entries.isEmpty else { return 0 }
        return entries.map(\.meanMilliseconds).reduce(0, +) / Double(entries.count)
    }

    func record(_ result: BenchmarkResult, binding: PortForwardBinding, path: String, at date: Date = .now) {
        guard Self.isLoopback(binding.localAddress) else { return }
        let entry = BenchmarkHistoryEntry(
            id: UUID(),
            recordedAt: date,
            loopbackEndpoint: "\(binding.localAddress):\(binding.localPort)",
            path: path,
            requested: result.requested,
            completed: result.completed,
            successful: result.successful,
            elapsed: result.elapsed,
            totalMilliseconds: result.totalMilliseconds
        )
        entries.insert(entry, at: 0)
        if entries.count > Self.maximumEntries {
            entries.removeLast(entries.count - Self.maximumEntries)
        }
    }

    func clear() {
        entries.removeAll()
    }

    func exportData() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(entries)
    }

    static func isLoopback(_ address: String) -> Bool {
        switch address.lowercased() {
        case "127.0.0.1", "::1", "localhost": true
        default: false
        }
    }
}

/// The minimal, exportable evidence from one local GET benchmark. This has no
/// request or response payload and exists only for the current app session
/// unless the operator explicitly exports it through a Save panel.
struct BenchmarkHistoryEntry: Codable, Hashable, Identifiable {
    let id: UUID
    let recordedAt: Date
    let loopbackEndpoint: String
    let path: String
    let requested: Int
    let completed: Int
    let successful: Int
    let elapsed: Double
    let totalMilliseconds: Double

    var failed: Int { completed - successful }
    var requestsPerSecond: Double { Double(completed) / max(elapsed, 0.001) }
    var meanMilliseconds: Double { completed == 0 ? 0 : totalMilliseconds / Double(completed) }
    var successRate: Double { completed == 0 ? 0 : Double(successful) / Double(completed) }
}
