import SwiftUI

struct SidebarView: View {
    @Environment(ClusterStore.self) private var store
    @Binding var selectedResourceType: ResourceType?
    let browseResources: () -> Void

    var body: some View {
        List(selection: $selectedResourceType) {
            Section("Cluster") {
                Label(store.selectedContext?.name ?? "Connecting…", systemImage: "server.rack")
                    .font(.headline)
                resourceRows(["pods", "services", "nodes", "namespaces", "events"])
            }
            Section("Favorites") {
                resourceRows(["deployments", "configmaps", "secrets", "persistentvolumeclaims"])
                Button(action: browseResources) {
                    Label("Browse All Resources…", systemImage: "square.grid.2x2")
                }
                .accessibilityHint("Open the resource picker")
            }
        }
        .listStyle(.sidebar)
        .navigationTitle("K9k")
        .safeAreaInset(edge: .bottom) {
            HStack(spacing: 6) {
                Image(systemName: store.isReadOnly ? "lock.fill" : "checkmark.shield")
                Text(store.isReadOnly ? "Read-only" : "Connected")
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
        }
    }

    @ViewBuilder
    private func resourceRows(_ names: [String]) -> some View {
        ForEach(names.compactMap { preferredResource(named: $0) }) { type in
            Label(type.kind, systemImage: icon(for: type))
                .tag(type)
        }
    }

    private func preferredResource(named name: String) -> ResourceType? {
        let candidates = store.discoveredResources.filter { $0.resource == name }
        return candidates.first(where: { $0.group.isEmpty }) ?? candidates.first
    }

    private func icon(for type: ResourceType) -> String {
        switch type.resource {
        case "pods": "shippingbox"
        case "deployments", "daemonsets", "statefulsets", "replicasets": "cube.box"
        case "services", "ingresses", "endpoints": "point.3.connected.trianglepath.dotted"
        case "configmaps", "secrets": "doc.text"
        case "nodes": "server.rack"
        default: "cube"
        }
    }

}
