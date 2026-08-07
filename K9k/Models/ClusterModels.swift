import Foundation

struct KubeContext: Codable, Identifiable, Hashable {
    let name: String
    let cluster: String
    let user: String
    let namespace: String?
    let active: Bool
    var id: String { name }
}

// K9sConfigSummary is intentionally metadata-only. K9k can use familiar
// resource aliases without importing executable plugin behaviour.
struct K9sConfigSummary: Codable, Hashable {
    let directory: String
    let files: [String: K9sConfigFile]
    let aliases: [K9sAlias]
    let hotkeys: [K9sHotkey]
    let plugins: [K9sPlugin]
    let views: [K9sCustomView]
    let jumps: [K9sJump]
}

struct K9sConfigFile: Codable, Hashable {
    let path: String
    let present: Bool
    let error: String?
}

struct K9sConfigDocument: Codable, Hashable {
    let name: String
    let path: String
    let exists: Bool
    let content: String
    let sha256: String
}

struct K9sAlias: Codable, Identifiable, Hashable {
    let name: String
    let target: String
    var id: String { name }
}

struct K9sHotkey: Codable, Identifiable, Hashable {
    let name: String
    let shortcut: String
    let description: String
    let command: String
    var id: String { name }
}

struct K9sPlugin: Codable, Identifiable, Hashable {
    let name: String
    let scopes: [String]
    let shortcut: String
    let description: String
    let command: String
    let args: [String]
    let background: Bool
    let confirm: Bool?
    let dangerous: Bool
    var id: String { name }
}

struct K9sCustomView: Codable, Identifiable, Hashable {
    let key: String
    let columns: [String]
    let sortColumn: String
    var id: String { key }
}

struct K9sJump: Codable, Identifiable, Hashable {
    let sourceGVR: String
    let targetGVR: String
    let labelSelector: String
    let fieldSelector: String
    let targetNamespace: String
    var id: String { sourceGVR }
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

/// A compact, credential-free record of a place the operator visited.  The
/// history deliberately stores discovery identity and list scope only; it
/// never serializes resource contents, kubeconfig data, or selections.
struct ResourceNavigationEntry: Codable, Identifiable, Hashable {
    let resourceTypeID: String
    let kind: String
    let resource: String
    let namespace: String
    let labelSelector: String
    let fieldSelector: String
    let contextName: String?
    let visitedAt: Date

    var id: String { "\(resourceTypeID)|\(namespace)|\(labelSelector)|\(fieldSelector)|\(visitedAt.timeIntervalSince1970)" }

    var title: String { kind }

    var detail: String {
        var values = [namespace == "All Namespaces" ? "All namespaces" : namespace]
        if !labelSelector.isEmpty { values.append("label: \(labelSelector)") }
        if !fieldSelector.isEmpty { values.append("field: \(fieldSelector)") }
        return values.joined(separator: " · ")
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

/// A metadata-only Helm v3 release timeline. K9k derives it from Helm's
/// standard storage Secret labels; it deliberately does not decode the opaque
/// release payload, which can contain values and rendered manifests.
struct HelmReleaseHistory: Codable, Hashable {
    let release: String
    let namespace: String?
    let revisions: [HelmReleaseRevision]
    let total: Int
    let truncated: Bool
}

struct HelmReleaseRevision: Codable, Identifiable, Hashable {
    let revision: Int
    let status: String
    let storageName: String
    let createdAt: Date
    let age: String
    var id: String { storageName }
}

struct NodeDrainResult: Codable, Hashable {
    let node: String
    let evicted: [NodeDrainPod]
    let skipped: [NodeDrainPod]
    let blocked: [NodeDrainPod]
    let failures: [NodeDrainPod]

    var hasIssues: Bool { !blocked.isEmpty || !failures.isEmpty }
}

struct NodeDrainPod: Codable, Hashable, Identifiable {
    let namespace: String
    let name: String
    let reason: String
    var id: String { "\(namespace)/\(name)/\(reason)" }
}

struct PodDebugResult: Codable, Hashable {
    let namespace: String
    let pod: String
    let container: String
    let image: String
}

struct RelationshipGraph: Codable, Hashable {
    let rootID: String
    let nodes: [RelationshipNode]
    let edges: [RelationshipEdge]
    let warnings: [String]

    var root: RelationshipNode? { nodes.first(where: { $0.id == rootID }) }

    func node(id: String) -> RelationshipNode? { nodes.first(where: { $0.id == id }) }
    func edges(relation: String) -> [RelationshipEdge] { edges.filter { $0.relation == relation } }
}

struct RelationshipNode: Codable, Identifiable, Hashable {
    let id: String
    let apiVersion: String
    let kind: String
    let namespace: String?
    let name: String
    let uid: String?
    let status: String?
    let resolved: Bool

    var title: String { "\(kind) / \(name)" }
    var subtitle: String {
        var values = [namespace?.isEmpty == false ? namespace! : "Cluster-scoped"]
        if let status, !status.isEmpty, status != "Unknown" { values.append(status) }
        if !resolved { values.append("unresolved reference") }
        return values.joined(separator: " · ")
    }
}

struct RelationshipEdge: Codable, Hashable, Identifiable {
    let from: String
    let to: String
    let relation: String
    var id: String { "\(from):\(relation):\(to)" }
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

/// The active context's answer to a Kubernetes SelfSubjectAccessReview.
/// K9k uses this for UI affordances, while the API server remains the final
/// authority for every request.
struct AccessReview: Codable, Hashable {
    let allowed: Bool
    let denied: Bool
    let reason: String?
    let evaluationError: String?
}

struct PortForwardBinding: Codable, Hashable {
    let namespace: String
    let pod: String
    let localAddress: String
    let localPort: Int
    let remotePort: Int

    var endpoint: String { "\(localAddress):\(localPort) → \(pod):\(remotePort)" }
}

struct ActivePortForward: Identifiable, Hashable {
    let streamID: String
    let binding: PortForwardBinding
    var id: String { streamID }
}

struct MetricsListResponse: Codable, Hashable {
    let apiVersion: String
    let resource: String
    let items: [ResourceMetrics]
}

struct ResourceMetrics: Codable, Identifiable, Hashable {
    let apiVersion: String
    let resource: String
    let namespace: String?
    let name: String
    let timestamp: Date
    let window: String
    let usage: [String: String]
    let containers: [ContainerMetrics]
    var id: String { "\(resource)/\(namespace ?? "")/\(name)" }
}

struct ContainerMetrics: Codable, Identifiable, Hashable {
    let name: String
    let usage: [String: String]
    var id: String { name }
}

/// The immutable selection guard returned with an editable Kubernetes object.
/// Its UID makes a stale editor incapable of applying to a replacement object
/// that happens to reuse the same name.
struct ManifestIdentity: Codable, Hashable {
    // Core Kubernetes resources omit `group` on the wire.
    let group: String?
    let version: String
    let resource: String
    let namespaced: Bool
    let namespace: String?
    let name: String
    let uid: String
    let kind: String
}

struct ManifestDocument: Codable, Hashable {
    let identity: ManifestIdentity
    let yaml: String
}

struct ManifestApplyResult: Codable, Hashable {
    let validated: Bool
    let applied: Bool
    let manifest: ManifestDocument
}

/// Result of a multi-document manifest import. Each item was dry-run before
/// any confirmed write starts; Kubernetes cannot make arbitrary object applies
/// transactional, so callers must not present this as an all-or-nothing batch.
struct ManifestBatchApplyResult: Codable, Hashable {
    let validated: Bool
    let applied: Bool
    let items: [ManifestDocument]
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
    var boolValue: Bool? { if case .bool(let value) = self { value } else { nil } }
    var intValue: Int? {
        if case .number(let value) = self, value.rounded() == value { return Int(value) }
        return nil
    }
    var objectValue: [String: JSONValue]? { if case .object(let value) = self { value } else { nil } }
    var arrayValue: [JSONValue]? { if case .array(let value) = self { value } else { nil } }
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
