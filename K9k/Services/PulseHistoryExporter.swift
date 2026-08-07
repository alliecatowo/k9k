import AppKit
import Foundation
import UniformTypeIdentifiers

/// Writes a user-initiated, bounded Pulse capture through standard macOS save
/// panels. It never stores samples automatically and serializes only the
/// normalized observation data already visible in Pulse.
@MainActor
enum PulseHistoryExporter {
    enum Format: String, CaseIterable {
        case json
        case csv

        var contentType: UTType {
            switch self {
            case .json: .json
            case .csv: .commaSeparatedText
            }
        }
    }

    static func save(_ snapshot: PulseHistoryExport, as format: Format, defaultName: String) throws {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "\(defaultName).\(format.rawValue)"
        panel.allowedContentTypes = [format.contentType]
        panel.canCreateDirectories = true
        panel.isExtensionHidden = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        try data(for: snapshot, as: format).write(to: url, options: .atomic)
    }

    static func data(for snapshot: PulseHistoryExport, as format: Format) throws -> Data {
        switch format {
        case .json:
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            return try encoder.encode(snapshot)
        case .csv:
            return Data(csv(snapshot).utf8)
        }
    }

    static func csv(_ snapshot: PulseHistoryExport) -> String {
        let formatter = ISO8601DateFormatter()
        let header = "timestamp,cpu_millicores,memory_mib,node_count,pod_count"
        let rows = snapshot.samples.map { sample in
            [
                formatter.string(from: sample.timestamp),
                sample.cpuMilli.formatted(.number.precision(.fractionLength(3))),
                sample.memoryMi.formatted(.number.precision(.fractionLength(3))),
                String(sample.nodeCount),
                String(sample.podCount),
            ]
            .map(csvField)
            .joined(separator: ",")
        }
        return ([header] + rows).joined(separator: "\n") + "\n"
    }

    private static func csvField(_ value: String) -> String {
        guard value.contains(",") || value.contains("\"") || value.contains("\n") else { return value }
        return "\"\(value.replacing("\"", with: "\"\""))\""
    }
}
