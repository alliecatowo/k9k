import SwiftUI

struct ResourceBrowserView: View {
    @Environment(ClusterStore.self) private var store
    @Binding var inspectorIsPresented: Bool
    @State private var sortOrder = [KeyPathComparator(\ResourceSummary.name)]

    var body: some View {
        @Bindable var store = store
        Group {
            if let type = store.selectedResourceType {
                Table(store.visibleResources, selection: $store.selectedResources, sortOrder: $sortOrder) {
                    TableColumn("Name", value: \.name) { resource in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(resource.name).fontWeight(.medium)
                            if resource.namespace?.isEmpty == false { Text(resource.namespace!).font(.caption).foregroundStyle(.secondary) }
                        }
                    }
                    .width(min: 220, ideal: 280)
                    TableColumn("Status", value: \.status) { Text($0.status).foregroundStyle(statusColor($0.status)) }
                        .width(min: 100, ideal: 140)
                    TableColumn("Age", value: \.age) { Text($0.age).monospacedDigit() }
                        .width(min: 54, ideal: 70)
                    TableColumn("Kind") { Text($0.kind).foregroundStyle(.secondary) }
                        .width(min: 110, ideal: 150)
                }
                .onChange(of: sortOrder) { _, newOrder in store.resources.sort(using: newOrder) }
                .contextMenu(forSelectionType: ResourceSummary.ID.self) { selection in
                    Button("Copy Name") { store.copySelectedName() }
                    Divider()
                    Button("Delete…", role: .destructive) { }
                        .disabled(store.isReadOnly || selection.isEmpty)
                } primaryAction: { _ in inspectorIsPresented = true }
                .overlay { if store.isLoading { ProgressView().controlSize(.small) } }
                .navigationTitle(type.kind)
            } else {
                ContentUnavailableView("No Resource Selected", systemImage: "cube.transparent", description: Text("Choose a Kubernetes resource from the resource catalog."))
            }
        }
        .safeAreaInset(edge: .top, spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "line.3.horizontal.decrease.circle")
                    .foregroundStyle(.secondary)
                TextField("Filter resource name, kind, or namespace", text: Bindable(store).searchText)
                    .textFieldStyle(.roundedBorder)
                if !store.searchText.isEmpty {
                    Button("Clear") { store.searchText = "" }
                        .buttonStyle(.borderless)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 9)
            .background(WindowBackgroundShapeStyle.windowBackground)
        }
        .background(WindowBackgroundShapeStyle.windowBackground)
    }

    private func statusColor(_ status: String) -> Color {
        switch status.lowercased() {
        case "running", "active", "bound", "ready": .green
        case "failed", "error", "unknown": .red
        case "pending", "terminating": .orange
        default: .secondary
        }
    }
}
