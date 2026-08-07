import SwiftUI

struct CommandPaletteView: View {
    @Environment(ClusterStore.self) private var store
    @Binding var isPresented: Bool
    @State private var query = ""

    private struct Item: Identifiable {
        let type: ResourceType
        let title: String
        let detail: String
        var id: String { "\(title)-\(type.id)" }
    }

    private var matches: [Item] {
        let normalized = query.lowercased().trimmingCharacters(in: .whitespaces)
        let resources = store.discoveredResources.filter { type in
            normalized.isEmpty || type.kind.lowercased().contains(normalized) || type.resource.lowercased().contains(normalized) || type.shortNames.map { $0.lowercased() }.contains(normalized)
        }.map { Item(type: $0, title: $0.kind, detail: $0.shortNames.joined(separator: ", ")) }
        let aliases = store.k9sAliases.compactMap { alias -> Item? in
            guard normalized.isEmpty || alias.name.lowercased().contains(normalized) || alias.target.lowercased().contains(normalized),
                  let type = store.resourceType(forK9sAlias: alias.name) else { return nil }
            return Item(type: type, title: alias.name, detail: "K9s alias → \(alias.target)")
        }
        return Array((aliases + resources).prefix(14))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            TextField("Go to a resource or action", text: $query)
                .textFieldStyle(.roundedBorder)
                .font(.title3)
            List(matches) { type in
                Button { Task { await store.selectResourceType(type.type) }; isPresented = false } label: {
                    HStack { Image(systemName: "cube"); Text(type.title); Spacer(); Text(type.detail).foregroundStyle(.secondary) }
                }
                .buttonStyle(.plain)
            }
            .frame(height: 280)
        }
        .padding()
        .frame(width: 520)
    }
}
