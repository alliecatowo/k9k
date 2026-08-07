import SwiftUI

struct K9kRootView: View {
    @Environment(ClusterStore.self) private var store
    @State private var inspectorIsPresented = true
    @State private var paletteIsPresented = false
    @State private var destructiveConfirmation = false
    @State private var logsPresented = false
    @State private var portForwardPresented = false
    @State private var scalePresented = false
    @State private var restartConfirmation = false
    @State private var terminalPresented = false
    @State private var manifestEditorPresented = false
    @State private var relationshipsPresented = false

    var body: some View {
        @Bindable var store = store
        NavigationSplitView {
            SidebarView(selectedResourceType: $store.selectedResourceType) { paletteIsPresented = true }
                .navigationSplitViewColumnWidth(min: 240, ideal: 260, max: 340)
        } detail: {
            ResourceBrowserView(inspectorIsPresented: $inspectorIsPresented, destructiveConfirmation: $destructiveConfirmation)
        }
        .navigationSplitViewStyle(.balanced)
        .inspector(isPresented: $inspectorIsPresented) {
            ResourceInspectorView(resource: store.resource(for: store.selectedResources.first), type: store.selectedResourceType, events: store.events)
                .inspectorColumnWidth(min: 280, ideal: 340, max: 480)
        }
        .toolbar { toolbar }
        .task { await store.connect() }
        .onChange(of: store.discoveredResources) { _, _ in store.ensureDefaultResourceSelection() }
        .onChange(of: store.selectedResourceType) { _, newValue in if newValue != nil { Task { await store.loadResources() } } }
        .onChange(of: store.selectedNamespace) { _, _ in Task { await store.loadResources() } }
        .onChange(of: store.selectedResources) { _, selection in
            Task {
                await store.loadEvents(for: store.resource(for: selection.first))
                await store.loadMetrics(for: store.resource(for: selection.first))
                await store.updateDeleteAccess()
                await store.updateScaleAccess()
                await store.updateRestartAccess()
                await store.updateExecAccess()
                await store.updateManifestAccess()
            }
        }
        .confirmationDialog("Delete selected resources?", isPresented: $destructiveConfirmation, titleVisibility: .visible) {
            Button("Delete", role: .destructive) { Task { await store.deleteSelected() } }
        } message: { Text("This changes resources in \(store.selectedContext?.name ?? "the active context").") }
        .confirmationDialog("Restart selected workload?", isPresented: $restartConfirmation, titleVisibility: .visible) {
            Button("Restart", role: .destructive) { Task { await store.restartSelected() } }
        } message: { Text("K9k updates the Pod template restart timestamp, which rolls this workload's Pods.") }
        .sheet(isPresented: $paletteIsPresented) { CommandPaletteView(isPresented: $paletteIsPresented) }
        .sheet(isPresented: $logsPresented) {
            if let resource = store.resource(for: store.selectedResources.first) { LogStreamView(resource: resource) }
        }
        .sheet(isPresented: $portForwardPresented) {
            if let resource = store.resource(for: store.selectedResources.first) { PortForwardView(resource: resource, isPresented: $portForwardPresented) }
        }
        .sheet(isPresented: $scalePresented) { ScaleWorkloadView(isPresented: $scalePresented) }
        .sheet(isPresented: $terminalPresented) {
            if let resource = store.resource(for: store.selectedResources.first) { TerminalSessionView(resource: resource) }
        }
        .sheet(isPresented: $manifestEditorPresented) {
            if let resource = store.resource(for: store.selectedResources.first), let type = store.selectedResourceType {
                ManifestEditorView(resource: resource, type: type)
            }
        }
        .sheet(isPresented: $relationshipsPresented) {
            if let resource = store.resource(for: store.selectedResources.first), let type = store.selectedResourceType {
                RelationshipGraphView(resource: resource, type: type)
            }
        }
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
                Button("Edit Manifest…") { manifestEditorPresented = true }
                    .disabled(!store.hasSelectedManifest)
                Button("View Relationships…") { relationshipsPresented = true }
                    .disabled(store.selectedResources.count != 1 || store.selectedResourceType == nil)
                if let resource = store.resource(for: store.selectedResources.first), resource.kind == "Pod" {
                    Button("View Logs") { logsPresented = true }
                    Button("Port Forward…") { portForwardPresented = true }
                    Button("Open Terminal…") { terminalPresented = true }
                        .disabled(!store.canOpenExec)
                }
                if store.isSelectedResourceScalable {
                    Button("Scale…") { scalePresented = true }
                        .disabled(!store.canScaleSelected)
                }
                if store.isSelectedResourceRestartable {
                    Button("Restart…", role: .destructive) { restartConfirmation = true }
                        .disabled(!store.canRestartSelected)
                }
                Divider()
                Toggle("Read-only Mode", isOn: Binding(get: { store.isReadOnly }, set: { store.isReadOnly = $0 }))
                Button("Delete…", role: .destructive) { destructiveConfirmation = true }
                    .disabled(!store.canDeleteSelected)
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
            Section("K9s compatibility") {
                if let config = store.k9sConfig {
                    LabeledContent("Configuration directory", value: config.directory)
                    LabeledContent("Aliases", value: "\(config.aliases.count)")
                    LabeledContent("Hotkeys", value: "\(config.hotkeys.count)")
                    LabeledContent("Custom views", value: "\(config.views.count)")
                    LabeledContent("Plugin declarations", value: "\(config.plugins.count)")
                    ForEach(config.files.keys.sorted(), id: \.self) { key in
                        if let file = config.files[key] {
                            LabeledContent(key.capitalized, value: file.present ? (file.error ?? "Loaded") : "Not present")
                        }
                    }
                    Button("Reload K9s Configuration") { Task { await store.loadK9sConfig() } }
                } else {
                    Text("K9s configuration is optional and could not be read.").foregroundStyle(.secondary)
                    Button("Reload K9s Configuration") { Task { await store.loadK9sConfig() } }
                }
            }
        }
        .padding()
        .frame(width: 520)
    }
}
