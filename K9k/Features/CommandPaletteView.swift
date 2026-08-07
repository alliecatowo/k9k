import SwiftUI

struct CommandPaletteView: View {
    @Environment(ClusterStore.self) private var store
    @Binding var isPresented: Bool
    @State private var query = ""

    private var matches: [ResourceType] {
        let normalized = query.lowercased().trimmingCharacters(in: .whitespaces)
        guard !normalized.isEmpty else { return Array(store.discoveredResources.prefix(14)) }
        return store.discoveredResources.filter { $0.kind.lowercased().contains(normalized) || $0.resource.lowercased().contains(normalized) || $0.shortNames.contains(normalized) }.prefix(14).map { $0 }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            TextField("Go to a resource or action", text: $query)
                .textFieldStyle(.roundedBorder)
                .font(.title3)
            List(matches) { type in
                Button { store.selectedResourceType = type; isPresented = false } label: {
                    HStack { Image(systemName: "cube"); Text(type.kind); Spacer(); Text(type.shortNames.joined(separator: ", ")).foregroundStyle(.secondary) }
                }
                .buttonStyle(.plain)
            }
            .frame(height: 280)
        }
        .padding()
        .frame(width: 520)
    }
}
