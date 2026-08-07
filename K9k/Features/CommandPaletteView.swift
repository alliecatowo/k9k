import SwiftUI

struct CommandPaletteView: View {
    @Environment(ClusterStore.self) private var store
    @Binding var isPresented: Bool
    @State private var query = ""
    @State private var helpIsPresented = false

    private enum Destination: Hashable {
        case resource(ResourceType)
        case recent(ResourceNavigationEntry)
        case back
        case forward
        case help
    }

    private struct Item: Identifiable {
        let title: String
        let detail: String
        let symbol: String
        let destination: Destination
        var id: String { "\(title)-\(detail)" }
    }

    private var matches: [Item] {
        let normalized = query.lowercased().trimmingCharacters(in: .whitespaces)
        let commands = [
            Item(title: "Go Back", detail: "Previous resource list", symbol: "chevron.left", destination: .back),
            Item(title: "Go Forward", detail: "Next resource list", symbol: "chevron.right", destination: .forward),
            Item(title: "Keyboard & Navigation Help", detail: "K9k command reference", symbol: "questionmark.circle", destination: .help),
        ].filter { item in
            normalized.isEmpty || item.title.lowercased().contains(normalized) || item.detail.lowercased().contains(normalized)
        }
        let recent = store.recentResourceNavigation.compactMap { entry -> Item? in
            guard store.discoveredResources.contains(where: { $0.id == entry.resourceTypeID }) else { return nil }
            guard normalized.isEmpty || entry.title.lowercased().contains(normalized) || entry.detail.lowercased().contains(normalized) || "recent".contains(normalized) else { return nil }
            return Item(title: "Recent: \(entry.title)", detail: entry.detail, symbol: "clock.arrow.circlepath", destination: .recent(entry))
        }
        let resources = store.discoveredResources.filter { type in
            normalized.isEmpty || type.kind.lowercased().contains(normalized) || type.resource.lowercased().contains(normalized) || type.shortNames.map { $0.lowercased() }.contains(normalized)
        }.map { Item(title: $0.kind, detail: $0.shortNames.joined(separator: ", "), symbol: "cube", destination: .resource($0)) }
        let aliases = store.k9sAliases.compactMap { alias -> Item? in
            guard normalized.isEmpty || alias.name.lowercased().contains(normalized) || alias.target.lowercased().contains(normalized),
                  let type = store.resourceType(forK9sAlias: alias.name) else { return nil }
            return Item(title: alias.name, detail: "K9s alias → \(alias.target)", symbol: "arrowshape.turn.up.right", destination: .resource(type))
        }
        return Array((commands + recent + aliases + resources).prefix(18))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            TextField("Go to a resource or action", text: $query)
                .textFieldStyle(.roundedBorder)
                .font(.title3)
            ScrollView {
                LazyVStack(spacing: 2) {
                    ForEach(matches) { item in
                        Button {
                            choose(item)
                        } label: {
                            HStack {
                                Image(systemName: item.symbol)
                                Text(item.title)
                                Spacer()
                                Text(item.detail).foregroundStyle(.secondary)
                            }
                            .contentShape(Rectangle())
                            .padding(.horizontal, 10)
                            .padding(.vertical, 8)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Open \(item.title)")
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(height: 280)
        }
        .padding()
        .frame(width: 520)
        .sheet(isPresented: $helpIsPresented) { NavigationHelpView(isPresented: $helpIsPresented) }
    }

    private func choose(_ item: Item) {
        switch item.destination {
        case let .resource(type):
            Task { await store.selectResourceType(type) }
            isPresented = false
        case let .recent(entry):
            Task { await store.openRecentNavigation(entry) }
            isPresented = false
        case .back:
            Task { await store.navigateBack() }
            isPresented = false
        case .forward:
            Task { await store.navigateForward() }
            isPresented = false
        case .help:
            helpIsPresented = true
        }
    }
}
