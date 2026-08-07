import Foundation

struct KubeContext: Codable, Identifiable, Hashable {
    let name: String
    let cluster: String
    let user: String
    let active: Bool
    var id: String { name }
}

// K9sConfigSummary is intentionally metadata-only. K9k can use familiar
// resource aliases without importing executable plugin behaviour.
struct K9sConfigSummary: Codable, Hashable {
    let directory: String
    let aliases: [K9sAlias]
}

struct K9sAlias: Codable, Identifiable, Hashable {
    let name: String
    let target: String
    var id: String { name }
}

struct ResourceType: Codable, Identifiable, Hashable {
    let group: String
    let version: String
    let resource: String
    let kind: String
    let namespaced: Bool
    let shortNames: [String]
    var id: String { "\(group)/\(version)/\(resource)" }
    var gvr: String { group.isEmpty ? "\(version)/\(resource)" : "\(group)/\(version)/\(resource)" }

    var groupDisplayName: String { group.isEmpty ? "core" : group }
    var requestParameters: JSONValue {
        .object(["group": .string(group), "version": .string(version), "resource": .string(resource), "namespaced": .bool(namespaced)])
    }
}

struct ResourceSummary: Codable, Identifiable, Hashable {
    let apiVersion: String
    let kind: String
    let namespace: String?
    let name: String
    let uid: String
    let createdAt: Date
    let age: String
    let status: String
    let labels: [String: String]?
    let raw: JSONValue?

    var id: String { uid.isEmpty ? "\(apiVersion)/\(namespace ?? "")/\(name)" : uid }
    var subtitle: String { namespace?.isEmpty == false ? namespace! : "Cluster-scoped" }
}

struct ClusterEvent: Codable, Identifiable, Hashable {
    let namespace: String
    let type: String
    let reason: String
    let message: String
    let count: Int
    let firstSeen: Date
    let lastSeen: Date
    let source: String?
    var id: String { "\(namespace)/\(reason)/\(message)/\(lastSeen.timeIntervalSince1970)" }
}

enum JSONValue: Codable, Hashable {
    case string(String), number(Double), bool(Bool), object([String: JSONValue]), array([JSONValue]), null

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() { self = .null }
        else if let value = try? container.decode(Bool.self) { self = .bool(value) }
        else if let value = try? container.decode(Double.self) { self = .number(value) }
        else if let value = try? container.decode(String.self) { self = .string(value) }
        else if let value = try? container.decode([String: JSONValue].self) { self = .object(value) }
        else { self = .array(try container.decode([JSONValue].self)) }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .string(let value): try container.encode(value)
        case .number(let value): try container.encode(value)
        case .bool(let value): try container.encode(value)
        case .object(let value): try container.encode(value)
        case .array(let value): try container.encode(value)
        case .null: try container.encodeNil()
        }
    }

    var stringValue: String? { if case .string(let value) = self { value } else { nil } }
    var objectValue: [String: JSONValue]? { if case .object(let value) = self { value } else { nil } }
}

enum NavigationDestination: String, CaseIterable, Identifiable {
    case overview, workloads, networking, configuration, storage, rbac, cluster, customResources, pulses, xray, portForwards
    var id: String { rawValue }
    var title: String {
        switch self { case .overview: "Overview"; case .workloads: "Workloads"; case .networking: "Networking"; case .configuration: "Configuration"; case .storage: "Storage"; case .rbac: "RBAC"; case .cluster: "Cluster"; case .customResources: "Custom Resources"; case .pulses: "Pulses"; case .xray: "XRay"; case .portForwards: "Port Forwards" }
    }
    var symbol: String {
        switch self { case .overview: "rectangle.3.group"; case .workloads: "cube.box"; case .networking: "point.3.connected.trianglepath.dotted"; case .configuration: "slider.horizontal.3"; case .storage: "externaldrive"; case .rbac: "lock.shield"; case .cluster: "server.rack"; case .customResources: "puzzlepiece.extension"; case .pulses: "waveform.path.ecg"; case .xray: "scope"; case .portForwards: "arrow.left.arrow.right" }
    }
}
