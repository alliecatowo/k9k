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
    let resourceVersion: String?
    let createdAt: Date
    let age: String
    let status: String
    let labels: [String: String]?
    let columns: [String: String]?
    let raw: JSONValue?

    var id: String { uid.isEmpty ? "\(apiVersion)/\(namespace ?? "")/\(name)" : uid }
    var subtitle: String { namespace?.isEmpty == false ? namespace! : "Cluster-scoped" }
}

/// Bounded resource-browser snapshot. Its list revision is handed straight to
/// the watch request so an update cannot disappear between listing and
/// watching a production-scale resource collection.
struct ResourceListPage: Codable, Hashable {
    let items: [ResourceSummary]
    let resourceVersion: String
    let `continue`: String?
    let remainingItemCount: Int?
}

/// A verified existing shell Pod. It is produced only after the backend has
/// checked the configured DaemonSet's controller UID, node placement, running
/// state, and configured container. No image, selector, or host access is
/// inferred by the macOS app.
struct NodeShellTarget: Codable, Hashable {
    let node: String
    let namespace: String
    let daemonSet: String
    let pod: String
    let container: String
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

/// Read-only projection of one Helm v3 Secret-backed release revision. The
/// sensitive payload is intentionally absent until the operator explicitly
/// acknowledges it in the inspector.
struct HelmReleaseInspection: Codable, Hashable {
    let release: String
    let namespace: String
    let revision: HelmReleaseRevision
    let chart: HelmChartMetadata
    let sensitiveContentAvailable: Bool
    let sensitive: HelmSensitiveContents?
}

struct HelmChartMetadata: Codable, Hashable {
    let name: String
    let version: String
    let appVersion: String?
    let apiVersion: String?
    let description: String?
    let type: String?
    let home: String?
    let icon: String?
    let kubeVersion: String?
    let deprecated: Bool
    let sources: [String]
    let keywords: [String]
}

/// The backend sets this only after an explicit acknowledgement. Manifest,
/// release notes, and configured values are all treated as potentially
/// sensitive because real-world charts routinely template credentials into
/// them.
struct HelmSensitiveContents: Codable, Hashable {
    let warning: String
    let manifest: String?
    let manifestTruncated: Bool
    let notes: String?
    let notesTruncated: Bool
    let valuesJSON: String?
    let valuesTruncated: Bool
}

/// A sensitive, server-side Helm upgrade preview. The app only receives this
/// after the operator acknowledges that rendered manifests and values can
/// expose production credentials.
struct HelmUpgradePlan: Codable, Hashable {
    let namespace: String
    let release: String
    let chartName: String
    let chartVersion: String
    let valuesMode: String
    let planDigest: String
    let manifest: String
    let manifestDigest: String
    let notes: String?
    let nextRevision: Int
}

/// Public metadata from a user-selected Helm repositories.yaml file. K9k
/// deliberately excludes every credential-related field from this model.
struct HelmRepositoryInspection: Codable, Hashable {
    let repositories: [HelmRepositorySource]
    let warnings: [String]
}

struct HelmRepositorySource: Codable, Hashable, Identifiable {
    let name: String
    let url: String
    var id: String { "\(name)\u{0}\(url)" }
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
    let truncated: Bool
    let maxDepth: Int

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

enum PortForwardConnectionState: Hashable {
    case connected
    case reconnecting(attempt: Int, maximumAttempts: Int)
    case failed(message: String)

    var isConnected: Bool {
        if case .connected = self { return true }
        return false
    }

    var detail: String {
        switch self {
        case .connected:
            "Connected"
        case let .reconnecting(attempt, maximumAttempts):
            "Reconnecting (attempt \(attempt) of \(maximumAttempts))"
        case let .failed(message):
            "Disconnected: \(message)"
        }
    }
}

/// A forward's identity survives transport reconnection. `streamID` changes
/// for every direct SPDY session, while `id` lets the native UI preserve the
/// same row and lets Stop cancel a pending retry as well as a live tunnel.
struct ActivePortForward: Identifiable, Hashable {
    let id: UUID
    var streamID: String
    var binding: PortForwardBinding
    var connectionState: PortForwardConnectionState
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

/// A per-collection status for Pulse. Kubernetes clusters may publish pod and
/// node metrics independently (or partially), so one unavailable endpoint
/// must not erase a usable companion collection or be presented as zero load.
enum MetricsCollectionState: String, Codable, Hashable {
    case available
    case unavailable
    case failed

    var displayName: String {
        switch self {
        case .available: "Available"
        case .unavailable: "Unavailable"
        case .failed: "Request failed"
        }
    }
}

struct MetricsCollectionDiagnostic: Identifiable, Codable, Hashable {
    let resource: String
    let state: MetricsCollectionState
    let itemCount: Int
    let message: String?
    let sampledAt: Date

    var id: String { resource }
    var title: String { resource.capitalized }
}

/// One bounded in-memory Pulse sample. Values are intentionally normalized to
/// millicores and MiB only for charting/export; the original Kubernetes
/// quantities remain available in the live metrics responses.
struct PulseHistorySample: Identifiable, Codable, Hashable {
    let timestamp: Date
    let cpuMilli: Double
    let memoryMi: Double
    let nodeCount: Int
    let podCount: Int

    var id: Date { timestamp }
}

/// Self-describing export payload for an operator's short Pulse capture.
/// History is strictly session-local and capped by PulseView; no cluster data
/// is persisted automatically.
struct PulseHistoryExport: Codable, Hashable {
    let schemaVersion: Int
    let exportedAt: Date
    let context: String?
    let sampleIntervalSeconds: Int
    let maximumSamples: Int
    let diagnostics: [MetricsCollectionDiagnostic]
    let samples: [PulseHistorySample]
}

/// Immutable identity passed from an inspector metric section into Pulse.
/// It intentionally contains no raw object data or credentials.
struct PulseDrilldownTarget: Identifiable, Hashable {
    let kind: String
    let namespace: String?
    let name: String

    var id: String { "\(kind)/\(namespace ?? "")/\(name)" }
    var metricResource: String { kind == "Pod" ? "pods" : "nodes" }
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

/// A read-only, server-side-apply preview of a selected live object. Both
/// documents are editor-safe YAML; `changes` is semantic while `diff` is a
/// copyable unified presentation of the same comparison.
struct ManifestDiffResult: Codable, Hashable {
    let identity: ManifestIdentity
    let live: ManifestDocument
    let preview: ManifestDocument
    let diff: String
    let changes: [ManifestDiffChange]
    let changed: Bool
    let truncated: Bool
}

struct ManifestDiffChange: Codable, Hashable, Identifiable {
    let path: String
    let operation: String
    let live: String?
    let preview: String?

    var id: String { "\(path)|\(operation)|\(live ?? "")|\(preview ?? "")" }
}

/// Result of a multi-document manifest import. Each item was dry-run before
/// any confirmed write starts; Kubernetes cannot make arbitrary object applies
/// transactional, so callers must not present this as an all-or-nothing batch.
struct ManifestBatchApplyResult: Codable, Hashable {
    let validated: Bool
    let applied: Bool
    let items: [ManifestDocument]
}

/// A previewed or completed deletion of the exact objects returned by a prior
/// manifest import. Kubernetes has no transaction across arbitrary resources,
/// so the UI must always describe confirmed deletes as potentially partial.
struct ManifestBatchDeleteResult: Codable, Hashable {
    let validated: Bool
    let deleted: Bool
    let items: [ManifestIdentity]
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
