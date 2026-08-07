import SwiftUI

/// A compact native XRay: edges remain explicit and readable instead of
/// drawing an unsearchable canvas. Selecting any node keeps the relationship
/// direction visible in one column and the Kubernetes identity in the other.
struct RelationshipGraphView: View {
    @Environment(ClusterStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    let resource: ResourceSummary
    let type: ResourceType

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Relationships").font(.headline)
                    Text("XRay for \(resource.kind) / \(resource.name)")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button("Refresh") { Task { await store.loadRelationships(for: resource, type: type) } }
                Button("Close") { dismiss() }
            }
            .padding()
            Divider()

            Group {
                if store.isLoadingRelationships && store.relationshipGraph == nil {
                    ProgressView("Reading Kubernetes relationships…")
                } else if let graph = store.relationshipGraph {
                    relationshipList(graph)
                } else {
                    ContentUnavailableView("No Relationship Snapshot", systemImage: "scope", description: Text("Refresh to read ownership, selectors, routes, and declared references."))
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(minWidth: 720, minHeight: 500)
        .task { await store.loadRelationships(for: resource, type: type) }
    }

    @ViewBuilder
    private func relationshipList(_ graph: RelationshipGraph) -> some View {
        List {
            if let root = graph.root {
                Section("Selected Resource") { nodeRow(root, relation: nil) }
            }
            relationshipSection("Owned by", relation: "owner", graph: graph)
            relationshipSection("Owns", relation: "owns", graph: graph)
            relationshipSection("Selects", relation: "selects", graph: graph)
            relationshipSection("Routes to", relation: "routes", graph: graph)
            relationshipSection("Uses", relation: "uses", graph: graph)
            if !graph.warnings.isEmpty {
                Section("Partial Snapshot") {
                    ForEach(graph.warnings, id: \.self) { warning in
                        Label(warning, systemImage: "exclamationmark.triangle")
                            .font(.caption).foregroundStyle(.orange)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func relationshipSection(_ title: String, relation: String, graph: RelationshipGraph) -> some View {
        let edges = graph.edges(relation: relation)
        if !edges.isEmpty {
            Section(title) {
                ForEach(edges) { edge in
                    if let node = graph.node(id: edge.from == graph.rootID ? edge.to : edge.from) {
                        nodeRow(node, relation: edge.relation)
                    }
                }
            }
        }
    }

    private func nodeRow(_ node: RelationshipNode, relation: String?) -> some View {
        HStack(spacing: 12) {
            Image(systemName: symbol(for: node.kind)).frame(width: 22).foregroundStyle(node.resolved ? Color.accentColor : Color.secondary)
            VStack(alignment: .leading, spacing: 3) {
                Text(node.title).fontWeight(.medium)
                Text(node.subtitle).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if let relation { Text(relation).font(.caption).padding(.horizontal, 7).padding(.vertical, 3).background(.quaternary, in: Capsule()) }
            if relation != nil {
                Button("Open") {
                    Task {
                        if await store.openRelationshipNode(node) { dismiss() }
                    }
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(!node.resolved)
                .help(node.resolved ? "Open \(node.kind)/\(node.name) in the resource browser" : "This relationship could not be resolved with the active Kubernetes identity")
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(relation ?? "selected") \(node.kind) \(node.name)")
    }

    private func symbol(for kind: String) -> String {
        switch kind {
        case "Pod": "shippingbox"
        case "Service": "point.3.connected.trianglepath.dotted"
        case "Deployment", "StatefulSet", "DaemonSet", "ReplicaSet", "Job", "CronJob": "cube.box"
        case "Secret": "key"
        case "ConfigMap": "doc.text"
        case "PersistentVolumeClaim": "externaldrive"
        default: "circle.dashed"
        }
    }
}
