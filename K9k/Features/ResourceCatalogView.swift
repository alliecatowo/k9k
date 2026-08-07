import SwiftUI

struct ResourceCatalogView: View {
    @Environment(ClusterStore.self) private var store
    @Binding var selection: ResourceType?
    @State private var filter = ""

    private var filteredTypes: [ResourceType] {
        let query = filter.lowercased()
        guard !query.isEmpty else { return store.discoveredResources }
        return store.discoveredResources.filter { $0.kind.lowercased().contains(query) || $0.resource.lowercased().contains(query) || $0.shortNames.contains(where: { $0.lowercased().contains(query) }) }
    }

    var body: some View {
        List(selection: $selection) {
            if filteredTypes.isEmpty {
                ContentUnavailableView.search(text: filter)
            } else {
                ForEach(Dictionary(grouping: filteredTypes, by: \.groupDisplayName).sorted(by: { $0.key < $1.key }), id: \.key) { group, types in
                    Section(group) {
                        ForEach(types.sorted(by: { $0.kind < $1.kind })) { type in
                            VStack(alignment: .leading, spacing: 2) {
                                Text(type.kind)
                                Text(type.shortNames.isEmpty ? type.resource : "\(type.resource) · \(type.shortNames.joined(separator: ", "))")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            .tag(type)
                        }
                    }
                }
            }
        }
        .navigationTitle("Resources")
        .searchable(text: $filter, placement: .sidebar, prompt: "Find a resource")
    }
}
