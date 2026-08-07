import SwiftUI

struct SidebarView: View {
    @Environment(ClusterStore.self) private var store
    @Binding var selectedResourceType: ResourceType?
    let browseResources: () -> Void

    var body: some View {
        List(selection: resourceSelection) {
            Section("Cluster") {
                Label(store.selectedContext?.name ?? "Connecting…", systemImage: "server.rack")
                    .font(.headline)
                resourceRows(["pods", "nodes", "namespaces", "events"])
            }
            Section("Workloads") {
                resourceRows(["deployments", "statefulsets", "daemonsets", "replicasets", "jobs", "cronjobs"])
            }
            Section("Networking") {
                resourceRows(["services", "ingresses", "networkpolicies", "endpointslices"])
            }
            Section("Configuration") {
                resourceRows(["configmaps", "secrets", "serviceaccounts"])
            }
            Section("Storage") {
                resourceRows(["persistentvolumeclaims", "persistentvolumes", "storageclasses"])
            }
            Section("Access") {
                resourceRows(["roles", "rolebindings", "clusterroles", "clusterrolebindings"])
            }
            Section {
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

    /// Sidebar selection is routed through the store rather than assigning the
    /// binding directly. Besides clearing stale GVR-specific selectors, this
    /// makes palette, sidebar, and history navigation share one state path.
    private var resourceSelection: Binding<ResourceType?> {
        Binding(
            get: { selectedResourceType },
            set: { newValue in
                guard let newValue else {
                    selectedResourceType = nil
                    return
                }
                Task { await store.selectResourceType(newValue) }
            }
        )
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
        case "persistentvolumeclaims", "persistentvolumes", "storageclasses": "externaldrive"
        case "roles", "rolebindings", "clusterroles", "clusterrolebindings", "serviceaccounts": "lock.shield"
        case "nodes": "server.rack"
        default: "cube"
        }
    }

}
