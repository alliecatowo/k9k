import SwiftUI

struct SidebarView: View {
    @Environment(ClusterStore.self) private var store
    @Binding var selection: NavigationDestination?

    var body: some View {
        List(selection: $selection) {
            Section("Cluster") {
                Label(store.selectedContext?.name ?? "Connecting…", systemImage: "server.rack")
                    .font(.headline)
                NavigationLink(value: NavigationDestination.overview) { Label("Overview", systemImage: "rectangle.3.group") }
                NavigationLink(value: NavigationDestination.pulses) { Label("Pulses", systemImage: "waveform.path.ecg") }
                NavigationLink(value: NavigationDestination.xray) { Label("XRay", systemImage: "scope") }
            }
            Section("Resources") {
                ForEach([NavigationDestination.workloads, .networking, .configuration, .storage, .rbac, .cluster, .customResources]) { destination in
                    NavigationLink(value: destination) { Label(destination.title, systemImage: destination.symbol) }
                }
            }
            Section("Operations") {
                NavigationLink(value: NavigationDestination.portForwards) { Label("Port Forwards", systemImage: "arrow.left.arrow.right") }
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
}
