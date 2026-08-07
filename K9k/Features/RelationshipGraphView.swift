import SwiftUI

/// A native, navigable XRay. The topology section deliberately renders every
/// resolved edge rather than a decorative static diagram: each endpoint opens
/// in the ordinary resource browser, preserving its live watch and actions.
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
            topologySection(graph)
            relationshipSection("Owned by", relation: "owner", graph: graph)
            relationshipSection("Owns", relation: "owns", graph: graph)
            relationshipSection("Selects", relation: "selects", graph: graph)
            relationshipSection("Routes to", relation: "routes", graph: graph)
            relationshipSection("Uses", relation: "uses", graph: graph)
            if !graph.warnings.isEmpty {
                Section(graph.truncated ? "Bounded Snapshot" : "Partial Snapshot") {
                    if graph.truncated {
                        Label("XRay stopped after \(graph.maxDepth) relationship hops or a safety limit.", systemImage: "scope")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
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
        // These are the direct connections that make the familiar K9s-style
        // relationship groups scannable. Deeper hops remain visible in the
        // explicit topology section above instead of being misrepresented as
        // immediate children of the selected resource.
        let edges = graph.edges(relation: relation).filter { $0.from == graph.rootID || $0.to == graph.rootID }
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

    @ViewBuilder
    private func topologySection(_ graph: RelationshipGraph) -> some View {
        if !graph.edges.isEmpty {
            Section("Topology · \(graph.nodes.count) resources") {
                ForEach(graph.edges) { edge in
                    if let source = graph.node(id: edge.from), let destination = graph.node(id: edge.to) {
                        HStack(spacing: 8) {
                            topologyEndpoint(source)
                            Image(systemName: "arrow.right")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.tertiary)
                            Text(edge.relation)
                                .font(.caption.weight(.medium))
                                .foregroundStyle(.secondary)
                                .frame(minWidth: 44)
                            Image(systemName: "arrow.right")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.tertiary)
                            topologyEndpoint(destination)
                        }
                        .accessibilityElement(children: .contain)
                        .accessibilityLabel("\(source.kind) \(source.name) \(edge.relation) \(destination.kind) \(destination.name)")
                    }
                }
            }
        }
    }

    private func topologyEndpoint(_ node: RelationshipNode) -> some View {
        Button {
            Task {
                if await store.openRelationshipNode(node) { dismiss() }
            }
        } label: {
            VStack(alignment: .leading, spacing: 1) {
                Text(node.name).lineLimit(1)
                Text(node.kind).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .buttonStyle(.plain)
        .disabled(!node.resolved)
        .help(node.resolved ? "Open \(node.kind)/\(node.name) in the resource browser" : "This reference could not be resolved with the active Kubernetes identity")
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
