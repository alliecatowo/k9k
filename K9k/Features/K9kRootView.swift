import SwiftUI

struct K9kRootView: View {
    @Environment(ClusterStore.self) private var store
    @State private var sidebarSelection: NavigationDestination? = .workloads
    @State private var inspectorIsPresented = true
    @State private var paletteIsPresented = false
    @State private var destructiveConfirmation = false

    var body: some View {
        @Bindable var store = store
        NavigationSplitView {
            SidebarView(selection: $sidebarSelection)
        } content: {
            ResourceCatalogView(selection: $store.selectedResourceType)
        } detail: {
            ResourceBrowserView(inspectorIsPresented: $inspectorIsPresented)
        }
        .navigationSplitViewStyle(.balanced)
        .inspector(isPresented: $inspectorIsPresented) {
            ResourceInspectorView(resource: store.resource(for: store.selectedResources.first), type: store.selectedResourceType)
                .inspectorColumnWidth(min: 280, ideal: 340, max: 480)
        }
        .toolbar { toolbar }
        .task { await store.connect() }
        .onChange(of: store.selectedResourceType) { _, newValue in if let newValue { Task { await store.selectResourceType(newValue) } } }
        .onChange(of: store.selectedNamespace) { _, _ in Task { await store.loadResources() } }
        .confirmationDialog("Delete selected resources?", isPresented: $destructiveConfirmation, titleVisibility: .visible) {
            Button("Delete", role: .destructive) { Task { await store.deleteSelected() } }
        } message: { Text("This changes resources in \(store.selectedContext?.name ?? "the active context").") }
        .sheet(isPresented: $paletteIsPresented) { CommandPaletteView(isPresented: $paletteIsPresented) }
        .alert("K9k could not complete the request", isPresented: Binding(get: { store.errorMessage != nil }, set: { if !$0 { store.errorMessage = nil } })) {
            Button("OK", role: .cancel) { store.errorMessage = nil }
        } message: { Text(store.errorMessage ?? "") }
    }

    @ToolbarContentBuilder private var toolbar: some ToolbarContent {
        ToolbarItem(placement: .navigation) {
            Picker("Context", selection: Binding(get: { store.selectedContext?.id ?? "" }, set: { id in if let context = store.contexts.first(where: { $0.id == id }) { Task { await store.selectContext(context) } } })) {
                ForEach(store.contexts) { context in Text(context.name).tag(context.id) }
            }
            .frame(maxWidth: 220)
            .accessibilityLabel("Kubernetes context")
        }
        ToolbarItem(placement: .principal) {
            Picker("Namespace", selection: Binding(get: { store.selectedNamespace }, set: { store.selectedNamespace = $0 })) {
                ForEach(store.namespaces, id: \.self) { Text($0).tag($0) }
            }
            .frame(maxWidth: 180)
            .accessibilityLabel("Namespace scope")
        }
        ToolbarItemGroup(placement: .primaryAction) {
            Button { Task { await store.loadResources() } } label: { Label("Refresh", systemImage: "arrow.clockwise") }
                .help("Refresh resource list")
            Button { paletteIsPresented = true } label: { Label("Open Command Palette", systemImage: "command") }
                .keyboardShortcut("k", modifiers: .command)
                .help("Open Command Palette")
            Button { inspectorIsPresented.toggle() } label: { Label("Toggle Inspector", systemImage: "sidebar.right") }
                .help("Show or hide inspector")
            Menu {
                Button("Copy Name", action: store.copySelectedName).disabled(store.selectedResources.isEmpty)
                Divider()
                Toggle("Read-only Mode", isOn: Binding(get: { store.isReadOnly }, set: { store.isReadOnly = $0 }))
                Button("Delete…", role: .destructive) { destructiveConfirmation = true }
                    .disabled(store.selectedResources.isEmpty || store.isReadOnly)
            } label: { Label("Resource Actions", systemImage: "ellipsis.circle") }
        }
    }
}

struct SettingsView: View {
    @Environment(ClusterStore.self) private var store
    var body: some View {
        @Bindable var store = store
        Form {
            Toggle("Read-only Mode", isOn: $store.isReadOnly)
            LabeledContent("Kubeconfig") { Text(ProcessInfo.processInfo.environment["KUBECONFIG"] ?? "~/.kube/config") }
        }
        .padding()
        .frame(width: 420)
    }
}
