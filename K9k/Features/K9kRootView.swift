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
    @State private var terminalMode: PodTerminalMode = .shell
    @State private var manifestEditorPresented = false
    @State private var relationshipsPresented = false
    @State private var nodeCordonConfirmation = false
    @State private var nodeDrainPresented = false
    @State private var debugPresented = false

    var body: some View {
        @Bindable var store = store
        NavigationSplitView {
            SidebarView(selectedResourceType: $store.selectedResourceType) { paletteIsPresented = true }
                .navigationSplitViewColumnWidth(min: 290, ideal: 320, max: 420)
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
                await store.updateAttachAccess()
                await store.updateDebugAccess()
                await store.updateManifestAccess()
                await store.updateNodePatchAccess()
                await store.updateNodeDrainAccess()
            }
        }
        .confirmationDialog("Delete selected resources?", isPresented: $destructiveConfirmation, titleVisibility: .visible) {
            Button("Delete", role: .destructive) { Task { await store.deleteSelected() } }
        } message: { Text("This changes resources in \(store.selectedContext?.name ?? "the active context").") }
        .confirmationDialog("Restart selected workload?", isPresented: $restartConfirmation, titleVisibility: .visible) {
            Button("Restart", role: .destructive) { Task { await store.restartSelected() } }
        } message: { Text("K9k updates the Pod template restart timestamp, which rolls this workload's Pods.") }
        .confirmationDialog("Cordon selected node?", isPresented: $nodeCordonConfirmation, titleVisibility: .visible) {
            Button("Cordon", role: .destructive) { Task { await store.setSelectedNodeUnschedulable(true) } }
        } message: { Text("New Pods will not schedule onto this node. Existing Pods are not evicted.") }
        .sheet(isPresented: $paletteIsPresented) { CommandPaletteView(isPresented: $paletteIsPresented) }
        .sheet(isPresented: $logsPresented) {
            if let resource = store.resource(for: store.selectedResources.first) { LogStreamView(resource: resource) }
        }
        .sheet(isPresented: $portForwardPresented) {
            if let resource = store.resource(for: store.selectedResources.first) { PortForwardView(resource: resource, isPresented: $portForwardPresented) }
        }
        .sheet(isPresented: $scalePresented) { ScaleWorkloadView(isPresented: $scalePresented) }
        .sheet(isPresented: $terminalPresented) {
            if let resource = store.resource(for: store.selectedResources.first) { TerminalSessionView(resource: resource, initialMode: terminalMode) }
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
        .sheet(isPresented: $nodeDrainPresented) {
            if let node = store.selectedNodeResource { NodeDrainView(node: node, isPresented: $nodeDrainPresented) }
        }
        .sheet(isPresented: $debugPresented) {
            if let resource = store.resource(for: store.selectedResources.first) { DebugContainerView(resource: resource, isPresented: $debugPresented) }
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
                    Button("Open Terminal…") { terminalMode = .shell; terminalPresented = true }
                        .disabled(!store.canOpenExec)
                    Button("Attach…") { terminalMode = .attach; terminalPresented = true }
                        .disabled(!store.canOpenAttach)
                    Button("Debug Container…") { debugPresented = true }
                        .disabled(!store.canDebugSelectedPod)
                }
                if store.isSelectedResourceScalable {
                    Button("Scale…") { scalePresented = true }
                        .disabled(!store.canScaleSelected)
                }
                if store.isSelectedResourceRestartable {
                    Button("Restart…", role: .destructive) { restartConfirmation = true }
                        .disabled(!store.canRestartSelected)
                }
                if let node = store.selectedNodeResource {
                    if node.raw?.objectValue?["spec"]?.objectValue?["unschedulable"]?.boolValue == true {
                        Button("Uncordon") { Task { await store.setSelectedNodeUnschedulable(false) } }.disabled(!store.canPatchSelectedNode)
                    } else {
                        Button("Cordon…", role: .destructive) { nodeCordonConfirmation = true }.disabled(!store.canPatchSelectedNode)
                    }
                    Button("Drain…") { nodeDrainPresented = true }
                        .disabled(!store.canDrainSelectedNode || node.raw?.objectValue?["spec"]?.objectValue?["unschedulable"]?.boolValue != true)
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
    @State private var editorFile = "aliases"
    @State private var editorPresented = false
    @State private var defaultNamespace = ""
    @State private var namespaceConfirmation = false
    var body: some View {
        @Bindable var store = store
        Form {
            Toggle("Read-only Mode", isOn: $store.isReadOnly)
            LabeledContent("Kubeconfig") { Text(ProcessInfo.processInfo.environment["KUBECONFIG"] ?? "~/.kube/config") }
            Section("Active kubectl context") {
                if let context = store.selectedContext {
                    LabeledContent("Context", value: context.name)
                    LabeledContent("Cluster", value: context.cluster)
                    Picker("Default namespace", selection: $defaultNamespace) {
                        Text("Kubernetes default").tag("")
                        ForEach(store.namespaces.filter { $0 != "All Namespaces" }, id: \.self) { Text($0).tag($0) }
                    }
                    Button("Save Default Namespace…") { namespaceConfirmation = true }
                        .disabled(defaultNamespace == (context.namespace ?? ""))
                    Text("This writes only the selected context's default namespace to kubeconfig. Cluster endpoints and credentials are never displayed or modified.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Section("Kubernetes Contexts") {
                ForEach(store.contexts) { context in
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(context.name).fontWeight(context.active ? .semibold : .regular)
                            Text("Cluster: \(context.cluster) · User: \(context.user)\(context.namespace?.isEmpty == false ? " · Namespace: \(context.namespace!)" : "")").font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        if context.active { Text("Active").font(.caption).foregroundStyle(.green) }
                        else { Button("Use") { Task { await store.selectContext(context) } } }
                    }
                }
                Text("Credentials remain in kubeconfig and are never displayed by K9k.").font(.caption).foregroundStyle(.secondary)
            }
            Section("K9s compatibility") {
                if let config = store.k9sConfig {
                    LabeledContent("Configuration directory", value: config.directory)
                    LabeledContent("Aliases", value: "\(config.aliases.count)")
                    LabeledContent("Hotkeys", value: "\(config.hotkeys.count)")
                    LabeledContent("Custom views", value: "\(config.views.count)")
                    LabeledContent("Plugin declarations", value: "\(config.plugins.count)")
                    ForEach(config.files.keys.sorted(), id: \.self) { key in
                        if let file = config.files[key] {
                            HStack { LabeledContent(key.capitalized, value: file.present ? (file.error ?? "Loaded") : "Not present"); Spacer(); Button("Edit") { editorFile = key; editorPresented = true } }
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
        .sheet(isPresented: $editorPresented) { K9sConfigEditorView(name: editorFile) }
        .task(id: store.selectedContext?.id) { defaultNamespace = store.selectedContext?.namespace ?? "" }
        .confirmationDialog("Save default namespace?", isPresented: $namespaceConfirmation, titleVisibility: .visible) {
            Button("Save to Kubeconfig") { Task { _ = await store.updateActiveContextNamespace(defaultNamespace) } }
        } message: {
            Text("K9k will update the default namespace for \(store.selectedContext?.name ?? "the active context") in your kubeconfig.")
        }
    }
}
