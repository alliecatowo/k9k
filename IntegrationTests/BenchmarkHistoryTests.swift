import Foundation

@main
struct BenchmarkHistoryTests {
    static func main() async throws {
        try await MainActor.run {
            let history = BenchmarkHistoryStore()
            let binding = PortForwardBinding(namespace: "ignored", pod: "never-recorded", localAddress: "127.0.0.1", localPort: 43123, remotePort: 80)

            for index in 0...BenchmarkHistoryStore.maximumEntries {
                history.record(
                    BenchmarkResult(requested: 200, completed: 200, successful: 200, elapsed: 2, totalMilliseconds: 10_000),
                    binding: binding,
                    path: "/healthz",
                    at: Date(timeIntervalSince1970: TimeInterval(index))
                )
            }

            precondition(history.entries.count == BenchmarkHistoryStore.maximumEntries, "history must discard the oldest completed run")
            precondition(history.entries.first?.recordedAt == Date(timeIntervalSince1970: TimeInterval(BenchmarkHistoryStore.maximumEntries)), "newest run must remain first")
            precondition(history.entries.last?.recordedAt == Date(timeIntervalSince1970: 1), "oldest retained run must be bounded")
            precondition(history.entries.allSatisfy { $0.loopbackEndpoint == "127.0.0.1:43123" }, "history must contain only the local endpoint")

            history.record(
                BenchmarkResult(requested: 1, completed: 1, successful: 1, elapsed: 1, totalMilliseconds: 1),
                binding: PortForwardBinding(namespace: "ignored", pod: "never-recorded", localAddress: "10.0.0.8", localPort: 80, remotePort: 80),
                path: "/",
                at: .now
            )
            precondition(history.entries.count == BenchmarkHistoryStore.maximumEntries, "non-loopback data must not enter history")

            let data = try history.exportData()
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            let exported = try decoder.decode([BenchmarkHistoryEntry].self, from: data)
            precondition(exported.count == BenchmarkHistoryStore.maximumEntries, "explicit JSON export must include each retained summary")
            precondition(exported.allSatisfy { $0.successRate == 1 && $0.meanMilliseconds == 50 }, "derived summary metrics must remain stable")

            history.clear()
            precondition(history.entries.isEmpty, "clear must remove in-memory entries")
        }
    }
}
