import SwiftUI

struct CommandPaletteView: View {
    @Environment(ClusterStore.self) private var store
    @Binding var isPresented: Bool
    @State private var query = ""
    @State private var helpIsPresented = false
    @State private var highlightedItemID: Item.ID?
    @FocusState private var queryIsFocused: Bool

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
                .focused($queryIsFocused)
                .accessibilityLabel("Command Palette Search")
                .accessibilityHint("Type to filter resources and commands. Use Up and Down Arrow to select a result, then Return to open it.")
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
                        .background {
                            RoundedRectangle(cornerRadius: 7, style: .continuous)
                                .fill(highlightedItemID == item.id ? Color.accentColor.opacity(0.18) : .clear)
                        }
                        .accessibilityLabel(item.title)
                        .accessibilityValue(item.detail)
                        .accessibilityHint("Press Return to open")
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityElement(children: .contain)
                .accessibilityLabel("Command Palette Results")
            }
            .frame(height: 280)
            HStack(spacing: 10) {
                Text("↑↓ Select")
                Text("↩ Open")
                Text("Esc Close")
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .accessibilityHidden(true)
        }
        .padding()
        .frame(width: 520)
        .sheet(isPresented: $helpIsPresented) { NavigationHelpView(isPresented: $helpIsPresented) }
        .onAppear {
            queryIsFocused = true
            selectFirstResult()
        }
        .onChange(of: query) { _, _ in selectFirstResult() }
        .onChange(of: matches.map(\.id)) { _, ids in
            if highlightedItemID == nil || !ids.contains(highlightedItemID ?? "") { highlightedItemID = ids.first }
        }
        .onKeyPress(.downArrow) {
            moveHighlight(by: 1)
            return .handled
        }
        .onKeyPress(.upArrow) {
            moveHighlight(by: -1)
            return .handled
        }
        .onKeyPress(.return) {
            if let item = matches.first(where: { $0.id == highlightedItemID }) { choose(item) }
            return .handled
        }
        .onKeyPress(.escape) {
            isPresented = false
            return .handled
        }
    }

    private func selectFirstResult() {
        highlightedItemID = matches.first?.id
    }

    private func moveHighlight(by offset: Int) {
        let items = matches
        guard !items.isEmpty else { return }
        guard let current = highlightedItemID, let currentIndex = items.firstIndex(where: { $0.id == current }) else {
            highlightedItemID = items.first?.id
            return
        }
        let nextIndex = (currentIndex + offset + items.count) % items.count
        highlightedItemID = items[nextIndex].id
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
