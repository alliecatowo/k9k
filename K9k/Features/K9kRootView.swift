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
    @State private var rollbackConfirmation = false
    @State private var cronJobTriggerConfirmation = false
    @State private var terminalPresented = false
    @State private var terminalMode: PodTerminalMode = .shell
    @State private var manifestEditorPresented = false
    @State private var relationshipsPresented = false
    @State private var nodeCordonConfirmation = false
    @State private var nodeDrainPresented = false
    @State private var debugPresented = false
    @State private var portForwardListPresented = false
    @State private var resourceSelectorsPresented = false
    @State private var pluginToRun: K9sPlugin?
    @State private var manifestImportPresented = false
    @State private var pulsePresented = false
    @State private var accessCheckPresented = false

    var body: some View {
        @Bindable var store = store
        navigationContent(selectedResourceType: $store.selectedResourceType)
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
                await store.updateRollbackAccess()
                await store.updateCronJobTriggerAccess()
                await store.updateExecAccess()
                await store.updateAttachAccess()
                await store.updateDebugAccess()
                await store.updateManifestAccess()
                await store.updateNodePatchAccess()
                await store.updateNodeDrainAccess()
            }
        }
        .modifier(rootPresentations(
            destructiveConfirmation: $destructiveConfirmation,
            restartConfirmation: $restartConfirmation,
            rollbackConfirmation: $rollbackConfirmation,
            cronJobTriggerConfirmation: $cronJobTriggerConfirmation,
            nodeCordonConfirmation: $nodeCordonConfirmation,
            paletteIsPresented: $paletteIsPresented,
            logsPresented: $logsPresented,
            portForwardPresented: $portForwardPresented,
            portForwardListPresented: $portForwardListPresented,
            scalePresented: $scalePresented,
            terminalPresented: $terminalPresented,
            terminalMode: $terminalMode,
            manifestEditorPresented: $manifestEditorPresented,
            relationshipsPresented: $relationshipsPresented,
            nodeDrainPresented: $nodeDrainPresented,
            debugPresented: $debugPresented,
            resourceSelectorsPresented: $resourceSelectorsPresented,
            pluginToRun: $pluginToRun,
            manifestImportPresented: $manifestImportPresented,
            pulsePresented: $pulsePresented,
            accessCheckPresented: $accessCheckPresented
        ))
    }

    @ViewBuilder private func navigationContent(selectedResourceType: Binding<ResourceType?>) -> some View {
        NavigationSplitView {
            SidebarView(selectedResourceType: selectedResourceType) { paletteIsPresented = true }
                // Kubernetes names, namespaces, and custom resources are often
                // long; a narrow Finder-like sidebar hides the operational
                // context people need while scanning a cluster.
                .navigationSplitViewColumnWidth(min: 340, ideal: 380, max: 480)
        } detail: {
            ResourceBrowserView(inspectorIsPresented: $inspectorIsPresented, destructiveConfirmation: $destructiveConfirmation)
        }
        .navigationSplitViewStyle(.balanced)
        .inspector(isPresented: $inspectorIsPresented) {
            ResourceInspectorView(resource: store.resource(for: store.selectedResources.first), type: store.selectedResourceType, events: store.events)
                .inspectorColumnWidth(min: 280, ideal: 340, max: 480)
        }
    }

    private func rootPresentations(
        destructiveConfirmation: Binding<Bool>, restartConfirmation: Binding<Bool>, rollbackConfirmation: Binding<Bool>, cronJobTriggerConfirmation: Binding<Bool>, nodeCordonConfirmation: Binding<Bool>,
        paletteIsPresented: Binding<Bool>, logsPresented: Binding<Bool>, portForwardPresented: Binding<Bool>, portForwardListPresented: Binding<Bool>,
        scalePresented: Binding<Bool>, terminalPresented: Binding<Bool>, terminalMode: Binding<PodTerminalMode>, manifestEditorPresented: Binding<Bool>,
        relationshipsPresented: Binding<Bool>, nodeDrainPresented: Binding<Bool>, debugPresented: Binding<Bool>, resourceSelectorsPresented: Binding<Bool>,
        pluginToRun: Binding<K9sPlugin?>, manifestImportPresented: Binding<Bool>, pulsePresented: Binding<Bool>, accessCheckPresented: Binding<Bool>
    ) -> some ViewModifier {
        RootPresentations(
            destructiveConfirmation: destructiveConfirmation, restartConfirmation: restartConfirmation, rollbackConfirmation: rollbackConfirmation, cronJobTriggerConfirmation: cronJobTriggerConfirmation,
            nodeCordonConfirmation: nodeCordonConfirmation, paletteIsPresented: paletteIsPresented, logsPresented: logsPresented,
            portForwardPresented: portForwardPresented, portForwardListPresented: portForwardListPresented, scalePresented: scalePresented,
            terminalPresented: terminalPresented, terminalMode: terminalMode, manifestEditorPresented: manifestEditorPresented,
            relationshipsPresented: relationshipsPresented, nodeDrainPresented: nodeDrainPresented, debugPresented: debugPresented,
            resourceSelectorsPresented: resourceSelectorsPresented, pluginToRun: pluginToRun, manifestImportPresented: manifestImportPresented, pulsePresented: pulsePresented,
            accessCheckPresented: accessCheckPresented
        )
    }

    private struct RootPresentations: ViewModifier {
        @Environment(ClusterStore.self) private var store
        @Binding var destructiveConfirmation: Bool
        @Binding var restartConfirmation: Bool
        @Binding var rollbackConfirmation: Bool
        @Binding var cronJobTriggerConfirmation: Bool
        @Binding var nodeCordonConfirmation: Bool
        @Binding var paletteIsPresented: Bool
        @Binding var logsPresented: Bool
        @Binding var portForwardPresented: Bool
        @Binding var portForwardListPresented: Bool
        @Binding var scalePresented: Bool
        @Binding var terminalPresented: Bool
        @Binding var terminalMode: PodTerminalMode
        @Binding var manifestEditorPresented: Bool
        @Binding var relationshipsPresented: Bool
        @Binding var nodeDrainPresented: Bool
        @Binding var debugPresented: Bool
        @Binding var resourceSelectorsPresented: Bool
        @Binding var pluginToRun: K9sPlugin?
        @Binding var manifestImportPresented: Bool
        @Binding var pulsePresented: Bool
        @Binding var accessCheckPresented: Bool

        func body(content: Content) -> some View {
            content
        .confirmationDialog("Delete selected resources?", isPresented: $destructiveConfirmation, titleVisibility: .visible) {
            Button("Delete", role: .destructive) { Task { await store.deleteSelected() } }
        } message: { Text("This changes resources in \(store.selectedContext?.name ?? "the active context").") }
        .confirmationDialog("Restart selected workload?", isPresented: $restartConfirmation, titleVisibility: .visible) {
            Button("Restart", role: .destructive) { Task { await store.restartSelected() } }
        } message: { Text("K9k updates the Pod template restart timestamp, which rolls this workload's Pods.") }
        .confirmationDialog("Roll back selected Deployment?", isPresented: $rollbackConfirmation, titleVisibility: .visible) {
            Button("Roll Back", role: .destructive) { Task { await store.rollbackSelected() } }
        } message: { Text(store.selectedRollbackDescription ?? "K9k will replace this Deployment's Pod template with the selected inactive ReplicaSet revision.") }
        .confirmationDialog("Trigger selected CronJob?", isPresented: $cronJobTriggerConfirmation, titleVisibility: .visible) {
            Button("Create Job", role: .destructive) { Task { await store.triggerSelectedCronJob() } }
        } message: { Text("K9k will create one Job from the CronJob's current template in \(store.selectedContext?.name ?? "the active context").") }
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
        .sheet(isPresented: $portForwardListPresented) { PortForwardListView(isPresented: $portForwardListPresented) }
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
        .sheet(isPresented: $resourceSelectorsPresented) {
            ResourceSelectorsView(isPresented: $resourceSelectorsPresented)
        }
        .sheet(item: $pluginToRun) { plugin in
            if let resource = store.resource(for: store.selectedResources.first) { K9sPluginRunnerView(plugin: plugin, resource: resource) }
        }
        .sheet(isPresented: $manifestImportPresented) { if let type = store.selectedResourceType { ManifestImportView(type: type) } }
        .sheet(isPresented: $pulsePresented) { PulseView(isPresented: $pulsePresented) }
        .sheet(isPresented: $accessCheckPresented) {
            AccessCheckView(initialType: store.selectedResourceType, initialResource: store.resource(for: store.selectedResources.first))
        }
        .alert("K9k could not complete the request", isPresented: Binding(get: { store.errorMessage != nil }, set: { if !$0 { store.errorMessage = nil } })) {
            Button("OK", role: .cancel) { store.errorMessage = nil }
        } message: { Text(store.errorMessage ?? "") }
    }

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
                ForEach(store.orderedNamespaces, id: \.self) { namespace in
                    Text(store.favoriteNamespaces.contains(namespace) ? "★ \(namespace)" : namespace).tag(namespace)
                }
            }
            .frame(maxWidth: 180)
            .accessibilityLabel("Namespace scope")
        }
        ToolbarItemGroup(placement: .primaryAction) {
            Button { Task { await store.loadResources() } } label: { Label("Refresh", systemImage: "arrow.clockwise") }
                .help("Refresh resource list")
            Menu("Namespace") {
                if store.selectedNamespace != "All Namespaces" {
                    Button(store.favoriteNamespaces.contains(store.selectedNamespace) ? "Remove Current Favourite" : "Favourite Current Namespace") {
                        store.toggleFavoriteNamespace(store.selectedNamespace)
                    }
                }
                if !store.favoriteNamespaces.isEmpty {
                    Divider()
                    ForEach(store.favoriteNamespaces, id: \.self) { namespace in
                        Button(namespace) { store.selectedNamespace = namespace }
                    }
                }
            }
            Button { resourceSelectorsPresented = true } label: { Label("Filter Resources", systemImage: "line.3.horizontal.decrease.circle") }
                .help("Filter the current Kubernetes resource list with label or field selectors")
            Button { manifestImportPresented = true } label: { Label("Import Manifest", systemImage: "square.and.arrow.down") }
                .disabled(store.selectedResourceType == nil || store.isReadOnly)
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
                if let type = store.selectedResourceType, let resource = store.resource(for: store.selectedResources.first) {
                    let jumps = store.customJumps(for: type)
                    if !jumps.isEmpty {
                        Menu("Custom Jump") {
                            ForEach(jumps) { jump in
                                Button("\(jump.targetGVR)") { Task { await store.performCustomJump(jump, from: resource, type: type) } }
                            }
                        }
                    }
                    let plugins = store.plugins(for: type)
                    if !plugins.isEmpty {
                        Menu("K9s Plugins") {
                            ForEach(plugins) { plugin in
                                Button(plugin.name) { pluginToRun = plugin }
                            }
                        }
                    }
                }
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
                if let resource = store.resource(for: store.selectedResources.first), resource.kind == "Service" {
                    Button("Port Forward…") { portForwardPresented = true }
                }
                if store.selectedResourceType?.gvr == "batch/v1/cronjobs", !store.selectedResources.isEmpty {
                    Button("Trigger CronJob…", role: .destructive) { cronJobTriggerConfirmation = true }
                        .disabled(!store.canTriggerSelectedCronJob)
                }
                if store.isSelectedResourceScalable {
                    Button("Scale…") { scalePresented = true }
                        .disabled(!store.canScaleSelected)
                }
                if store.isSelectedResourceRestartable {
                    Button("Restart…", role: .destructive) { restartConfirmation = true }
                        .disabled(!store.canRestartSelected)
                }
                if store.selectedRollbackDescription != nil {
                    Button("Roll Back to This Revision…", role: .destructive) { rollbackConfirmation = true }
                        .disabled(!store.canRollbackSelected)
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
                Button("Check Access…") { accessCheckPresented = true }
                    .disabled(store.selectedResourceType == nil)
                Button("Pulse…") { pulsePresented = true }
                Button("Helm Releases") { Task { await store.openHelmReleases() } }
                Button("Active Port Forwards…") { portForwardListPresented = true }
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
    @State private var contextManagerPresented = false
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
                Button("Manage Contexts…") { contextManagerPresented = true }
                Text("Credentials remain in kubeconfig and are never displayed by K9k.").font(.caption).foregroundStyle(.secondary)
            }
            Section("Namespace favourites") {
                if store.favoriteNamespaces.isEmpty {
                    Text("Choose a namespace, then use the Namespace toolbar menu to add it here.").foregroundStyle(.secondary)
                } else {
                    ForEach(store.favoriteNamespaces, id: \.self) { namespace in
                        HStack { Text(namespace); Spacer(); Button("Remove") { store.toggleFavoriteNamespace(namespace) } }
                    }
                }
            }
            Section("K9s compatibility") {
                if let config = store.k9sConfig {
                    LabeledContent("Configuration directory", value: config.directory)
                    LabeledContent("Aliases", value: "\(config.aliases.count)")
                    LabeledContent("Hotkeys", value: "\(config.hotkeys.count)")
                    LabeledContent("Custom views", value: "\(config.views.count)")
                    LabeledContent("Custom jumps", value: "\(config.jumps.count)")
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
        .sheet(isPresented: $contextManagerPresented) { KubeconfigContextManagerView(isPresented: $contextManagerPresented) }
        .task(id: store.selectedContext?.id) { defaultNamespace = store.selectedContext?.namespace ?? "" }
        .confirmationDialog("Save default namespace?", isPresented: $namespaceConfirmation, titleVisibility: .visible) {
            Button("Save to Kubeconfig") { Task { _ = await store.updateActiveContextNamespace(defaultNamespace) } }
        } message: {
            Text("K9k will update the default namespace for \(store.selectedContext?.name ?? "the active context") in your kubeconfig.")
        }
    }
}
