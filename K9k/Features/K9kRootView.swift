import SwiftUI

struct K9kRootView: View {
    @Environment(ClusterStore.self) private var store
    @State private var splitVisibility: NavigationSplitViewVisibility = .all
    @State private var inspectorIsPresented = true
    @State private var inspectorRevealGeneration = 0
    @State private var workspaceWidth = WorkspaceGeometry.defaultWindowWidth
    @State private var renderedSidebarWidth = WorkspaceGeometry.sidebarMinimumWidth
    @State private var renderedInspectorWidth = WorkspaceGeometry.inspectorMinimumWidth
    @State private var compactLayoutIsActive = false
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
    @State private var podFileTransferPresented = false
    @State private var imageScanPresented = false
    @State private var manifestEditorPresented = false
    @State private var relationshipsPresented = false
    @State private var nodeCordonConfirmation = false
    @State private var nodeDrainPresented = false
    @State private var nodeShellPresented = false
    @State private var debugPresented = false
    @State private var portForwardListPresented = false
    @State private var benchmarkHistory = BenchmarkHistoryStore()
    @State private var resourceSelectorsPresented = false
    @State private var pluginToRun: K9sPlugin?
    @State private var manifestImportPresented = false
    @State private var pulsePresented = false
    @State private var accessCheckPresented = false
    @State private var effectiveRBACPresented = false
    @State private var navigationHelpPresented = false
    @State private var hostSSHPresented = false

    var body: some View {
        @Bindable var store = store
        let selectionHydration = SelectionHydration(
            contextID: store.selectedContext?.id,
            resourceTypeID: store.selectedResourceType?.id,
            selectedResourceIDs: store.selectedResources
        )
        navigationContent(selectedResourceType: $store.selectedResourceType)
        .toolbar { toolbar }
        .onGeometryChange(for: CGFloat.self) { geometry in
            geometry.size.width
        } action: { width in
            workspaceWidth = width
            let compact = WorkspaceGeometry.usesCompactSideColumns(windowWidth: width)
            guard compact != compactLayoutIsActive else { return }
            compactLayoutIsActive = compact

            // Do not turn a restored wide inspector into an unsolicited
            // modal sheet when the app first lands on a compact display.
            // Once compact, an explicit inspector action opens the contained
            // sheet and subsequent geometry updates leave it alone.
            if compact, inspectorIsPresented {
                var transaction = Transaction()
                transaction.disablesAnimations = true
                withTransaction(transaction) {
                    inspectorIsPresented = false
                }
            }
        }
        .task { await store.connect() }
        .onChange(of: store.discoveredResources) { _, _ in store.ensureDefaultResourceSelection() }
        .onChange(of: store.selectedResourceType) { _, newValue in if newValue != nil { Task { await store.loadResources() } } }
        .onChange(of: store.selectedNamespace) { _, _ in Task { await store.loadResources() } }
        .task(id: selectionHydration) {
            // Selection hydration is ordinary data work, not part of the
            // inspector animation. Starting it immediately removes a fixed
            // 300 ms penalty from every row click. task(id:) cancels the
            // previous selection's work, while the store revalidates the
            // selected resource after each awaited backend request.
            guard !Task.isCancelled,
                  selectionHydration == currentSelectionHydration else { return }
            await store.loadSelectedResourceSummary(for: selectionHydration.selectedResourceIDs.first)
        }
        .onChange(of: store.pulseDrilldownTarget) { _, target in
            if target != nil { pulsePresented = true }
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
            benchmarkHistory: benchmarkHistory,
            scalePresented: $scalePresented,
            terminalPresented: $terminalPresented,
            terminalMode: $terminalMode,
            manifestEditorPresented: $manifestEditorPresented,
            relationshipsPresented: $relationshipsPresented,
            nodeDrainPresented: $nodeDrainPresented,
            nodeShellPresented: $nodeShellPresented,
            debugPresented: $debugPresented,
            resourceSelectorsPresented: $resourceSelectorsPresented,
            pluginToRun: $pluginToRun,
            manifestImportPresented: $manifestImportPresented,
            pulsePresented: $pulsePresented,
            accessCheckPresented: $accessCheckPresented,
            navigationHelpPresented: $navigationHelpPresented,
            imageScanPresented: $imageScanPresented,
            hostSSHPresented: $hostSSHPresented
        ))
        .sheet(isPresented: $podFileTransferPresented) {
            if let resource = store.resource(for: store.selectedResources.first) {
                PodFileTransferView(resource: resource)
            }
        }
        .sheet(isPresented: $imageScanPresented) {
            if let resource = store.resource(for: store.selectedResources.first) {
                ImageScanView(resource: resource)
            }
        }
        .sheet(isPresented: $effectiveRBACPresented) {
            EffectiveRBACView(initialResource: store.resource(for: store.selectedResources.first))
        }
    }

    private var currentSelectionHydration: SelectionHydration {
        SelectionHydration(
            contextID: store.selectedContext?.id,
            resourceTypeID: store.selectedResourceType?.id,
            selectedResourceIDs: store.selectedResources
        )
    }

    /// Includes cluster and GVR identity so a same-UID selection reached
    /// through a context or navigation change cannot reuse stale hydration.
    private struct SelectionHydration: Equatable {
        let contextID: String?
        let resourceTypeID: String?
        let selectedResourceIDs: Set<ResourceSummary.ID>
    }

    /// Records the transition before presenting the native inspector so its
    /// content can distinguish a real reveal from an ordinary row change.
    private var inspectorPresentation: Binding<Bool> {
        Binding(
            get: { inspectorIsPresented },
            set: { newValue in
                guard newValue != inspectorIsPresented else { return }
                if newValue { inspectorRevealGeneration &+= 1 }
                inspectorIsPresented = newValue
            }
        )
    }

    @ViewBuilder private func navigationContent(selectedResourceType: Binding<ResourceType?>) -> some View {
        let usesCompactSideColumns = WorkspaceGeometry.usesCompactSideColumns(windowWidth: workspaceWidth)
        let availableBrowserWidth = WorkspaceGeometry.browserWidth(
            windowWidth: workspaceWidth,
            sidebarWidth: splitVisibility == .detailOnly ? 0 : renderedSidebarWidth,
            inspectorWidth: !usesCompactSideColumns && inspectorIsPresented
                ? renderedInspectorWidth
                : 0
        )
        let workspace = NavigationSplitView(columnVisibility: $splitVisibility) {
            SidebarView(selectedResourceType: selectedResourceType) { paletteIsPresented = true }
                // Kubernetes names, namespaces, and custom resources are often
                // long; a narrow Finder-like sidebar hides the operational
                // context people need while scanning a cluster.
                .navigationSplitViewColumnWidth(
                    min: WorkspaceGeometry.sidebarMinimumWidth,
                    ideal: usesCompactSideColumns ? WorkspaceGeometry.sidebarMinimumWidth : WorkspaceGeometry.sidebarIdealWidth,
                    max: usesCompactSideColumns ? WorkspaceGeometry.sidebarMinimumWidth : WorkspaceGeometry.sidebarMaximumWidth
                )
                .onGeometryChange(for: CGFloat.self) { geometry in
                    geometry.size.width
                } action: { width in
                    let budgetWidth = WorkspaceGeometry.quantizedMeasuredWidth(width)
                    if renderedSidebarWidth != budgetWidth {
                        renderedSidebarWidth = budgetWidth
                    }
                }
        } detail: {
            ResourceBrowserView(
                inspectorIsPresented: inspectorPresentation,
                destructiveConfirmation: $destructiveConfirmation,
                availableColumnWidth: availableBrowserWidth
            )
        }
        .navigationSplitViewStyle(.balanced)

        if usesCompactSideColumns {
            workspace
                .sheet(isPresented: inspectorPresentation) {
                    NavigationStack {
                        ResourceInspectorView(
                            resource: store.resource(for: store.selectedResources.first),
                            type: store.selectedResourceType,
                            events: store.events,
                            isPresented: inspectorIsPresented,
                            presentationGeneration: inspectorRevealGeneration
                        )
                        .frame(
                            minWidth: WorkspaceGeometry.compactInspectorMinimumWidth,
                            idealWidth: WorkspaceGeometry.compactInspectorIdealWidth,
                            minHeight: WorkspaceGeometry.compactInspectorMinimumHeight,
                            idealHeight: WorkspaceGeometry.compactInspectorIdealHeight
                        )
                        .toolbar {
                            ToolbarItem(placement: .confirmationAction) {
                                Button("Done") { inspectorPresentation.wrappedValue = false }
                                    .keyboardShortcut(.defaultAction)
                            }
                        }
                    }
                }
        } else {
            // Tahoe can lay out a native .inspector partly beyond its owning
            // window even when the declared column minimum mathematically
            // fits. An in-flow HSplitView preserves the same resizable
            // trailing-inspector interaction while making the window itself
            // the hard clipping and sizing boundary. Keep the panel mounted
            // at zero width when collapsed so its prepared overview and tab
            // selection survive repeated toggles and the browser is never
            // reparented into a different layout hierarchy.
            HSplitView {
                workspace
                    .frame(minWidth: WorkspaceGeometry.sidebarMinimumWidth + WorkspaceGeometry.browserMinimumWidth)
                    .layoutPriority(1)

                ResourceInspectorView(
                    resource: store.resource(for: store.selectedResources.first),
                    type: store.selectedResourceType,
                    events: store.events,
                    isPresented: inspectorIsPresented,
                    presentationGeneration: inspectorRevealGeneration
                )
                .frame(
                    minWidth: inspectorIsPresented ? WorkspaceGeometry.inspectorMinimumWidth : 0,
                    idealWidth: inspectorIsPresented ? WorkspaceGeometry.inspectorIdealWidth : 0,
                    maxWidth: inspectorIsPresented ? WorkspaceGeometry.inspectorMaximumWidth : 0,
                    maxHeight: .infinity,
                    alignment: .topLeading
                )
                .opacity(inspectorIsPresented ? 1 : 0)
                .allowsHitTesting(inspectorIsPresented)
                .accessibilityHidden(!inspectorIsPresented)
                .background(.regularMaterial)
                .clipped()
                .onGeometryChange(for: CGFloat.self) { geometry in
                    geometry.size.width
                } action: { width in
                    guard inspectorIsPresented else { return }
                    let budgetWidth = WorkspaceGeometry.quantizedMeasuredWidth(width)
                    if renderedInspectorWidth != budgetWidth {
                        renderedInspectorWidth = budgetWidth
                    }
                }
            }
        }
    }

    private func rootPresentations(
        destructiveConfirmation: Binding<Bool>, restartConfirmation: Binding<Bool>, rollbackConfirmation: Binding<Bool>, cronJobTriggerConfirmation: Binding<Bool>, nodeCordonConfirmation: Binding<Bool>,
        paletteIsPresented: Binding<Bool>, logsPresented: Binding<Bool>, portForwardPresented: Binding<Bool>, portForwardListPresented: Binding<Bool>,
        benchmarkHistory: BenchmarkHistoryStore, scalePresented: Binding<Bool>, terminalPresented: Binding<Bool>, terminalMode: Binding<PodTerminalMode>, manifestEditorPresented: Binding<Bool>,
        relationshipsPresented: Binding<Bool>, nodeDrainPresented: Binding<Bool>, nodeShellPresented: Binding<Bool>, debugPresented: Binding<Bool>, resourceSelectorsPresented: Binding<Bool>,
        pluginToRun: Binding<K9sPlugin?>, manifestImportPresented: Binding<Bool>, pulsePresented: Binding<Bool>, accessCheckPresented: Binding<Bool>, navigationHelpPresented: Binding<Bool>, imageScanPresented: Binding<Bool>, hostSSHPresented: Binding<Bool>
    ) -> some ViewModifier {
        RootPresentations(
            destructiveConfirmation: destructiveConfirmation, restartConfirmation: restartConfirmation, rollbackConfirmation: rollbackConfirmation, cronJobTriggerConfirmation: cronJobTriggerConfirmation,
            nodeCordonConfirmation: nodeCordonConfirmation, paletteIsPresented: paletteIsPresented, logsPresented: logsPresented,
            portForwardPresented: portForwardPresented, portForwardListPresented: portForwardListPresented, benchmarkHistory: benchmarkHistory, scalePresented: scalePresented,
            terminalPresented: terminalPresented, terminalMode: terminalMode, manifestEditorPresented: manifestEditorPresented,
            relationshipsPresented: relationshipsPresented, nodeDrainPresented: nodeDrainPresented, nodeShellPresented: nodeShellPresented, debugPresented: debugPresented,
            resourceSelectorsPresented: resourceSelectorsPresented, pluginToRun: pluginToRun, manifestImportPresented: manifestImportPresented, pulsePresented: pulsePresented,
            accessCheckPresented: accessCheckPresented, navigationHelpPresented: navigationHelpPresented, imageScanPresented: imageScanPresented, hostSSHPresented: hostSSHPresented
        )
    }

    private struct RootPresentations: ViewModifier {
        fileprivate static let imageScannableKinds: Set<String> = ["Pod", "Deployment", "StatefulSet", "DaemonSet", "ReplicaSet", "ReplicationController", "Job", "CronJob"]
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
        let benchmarkHistory: BenchmarkHistoryStore
        @Binding var scalePresented: Bool
        @Binding var terminalPresented: Bool
        @Binding var terminalMode: PodTerminalMode
        @Binding var manifestEditorPresented: Bool
        @Binding var relationshipsPresented: Bool
        @Binding var nodeDrainPresented: Bool
        @Binding var nodeShellPresented: Bool
        @Binding var debugPresented: Bool
        @Binding var resourceSelectorsPresented: Bool
        @Binding var pluginToRun: K9sPlugin?
        @Binding var manifestImportPresented: Bool
        @Binding var pulsePresented: Bool
        @Binding var accessCheckPresented: Bool
        @Binding var navigationHelpPresented: Bool
        @Binding var imageScanPresented: Bool
        @Binding var hostSSHPresented: Bool

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
        .sheet(isPresented: $portForwardListPresented) { PortForwardListView(isPresented: $portForwardListPresented, benchmarkHistory: benchmarkHistory) }
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
        .sheet(isPresented: $nodeShellPresented) {
            if let node = store.selectedNodeResource { NodeShellView(node: node, isPresented: $nodeShellPresented) }
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
        .sheet(isPresented: $manifestImportPresented) { ManifestWorkspaceView() }
        .sheet(isPresented: $pulsePresented, onDismiss: { store.clearPulseDrilldown() }) {
            PulseView(isPresented: $pulsePresented, drilldownTarget: store.pulseDrilldownTarget)
        }
        .sheet(isPresented: $accessCheckPresented) {
            AccessCheckView(initialType: store.selectedResourceType, initialResource: store.resource(for: store.selectedResources.first))
        }
        .sheet(isPresented: $navigationHelpPresented) { NavigationHelpView(isPresented: $navigationHelpPresented) }
        .sheet(isPresented: $hostSSHPresented) { HostSSHTerminalView() }
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
            Button { Task { await store.navigateBack() } } label: { Label("Go Back", systemImage: "chevron.left") }
                .disabled(!store.canNavigateBack)
                .keyboardShortcut("[", modifiers: .command)
                .help("Go to the previous resource list")
            Button { Task { await store.navigateForward() } } label: { Label("Go Forward", systemImage: "chevron.right") }
                .disabled(!store.canNavigateForward)
                .keyboardShortcut("]", modifiers: .command)
                .help("Go to the next resource list")
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
                .disabled(store.isReadOnly)
            Button { paletteIsPresented = true } label: { Label("Open Command Palette", systemImage: "command") }
                .keyboardShortcut("k", modifiers: .command)
                .help("Open Command Palette")
            Button { navigationHelpPresented = true } label: { Label("Navigation Help", systemImage: "questionmark.circle") }
                .keyboardShortcut("?", modifiers: .command)
                .help("Open navigation and command help")
            Button { inspectorPresentation.wrappedValue.toggle() } label: { Label("Toggle Inspector", systemImage: "sidebar.right") }
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
                        .disabled(store.isReadOnly)
                    Button("Attach…") { terminalMode = .attach; terminalPresented = true }
                        .disabled(store.isReadOnly)
                    Button("Debug Container…") { debugPresented = true }
                        .disabled(store.isReadOnly)
                    Button("File Transfer…") { podFileTransferPresented = true }
                        .disabled(store.isReadOnly)
                }
                if let resource = store.resource(for: store.selectedResources.first), RootPresentations.imageScannableKinds.contains(resource.kind) {
                    Button("Image Scan…") { imageScanPresented = true }
                }
                if let resource = store.resource(for: store.selectedResources.first), resource.kind == "Service" {
                    Button("Port Forward…") { portForwardPresented = true }
                }
                if store.selectedResourceType?.gvr == "batch/v1/cronjobs", !store.selectedResources.isEmpty {
                    Button("Trigger CronJob…", role: .destructive) { cronJobTriggerConfirmation = true }
                        .disabled(store.isReadOnly)
                }
                if store.isSelectedResourceScalable {
                    Button("Scale…") { scalePresented = true }
                        .disabled(store.isReadOnly)
                }
                if store.isSelectedResourceRestartable {
                    Button("Restart…", role: .destructive) { restartConfirmation = true }
                        .disabled(store.isReadOnly)
                }
                if store.selectedRollbackDescription != nil {
                    Button("Roll Back to This Revision…", role: .destructive) { rollbackConfirmation = true }
                        .disabled(store.isReadOnly)
                }
                if let node = store.selectedNodeResource {
                    if node.raw?.objectValue?["spec"]?.objectValue?["unschedulable"]?.boolValue == true {
                        Button("Uncordon") { Task { await store.setSelectedNodeUnschedulable(false) } }.disabled(store.isReadOnly)
                    } else {
                        Button("Cordon…", role: .destructive) { nodeCordonConfirmation = true }.disabled(store.isReadOnly)
                    }
                    Button("Drain…") { nodeDrainPresented = true }
                        .disabled(store.isReadOnly || node.raw?.objectValue?["spec"]?.objectValue?["unschedulable"]?.boolValue != true)
                    Button("Node Shell…") { nodeShellPresented = true }
                        .disabled(store.isReadOnly)
                }
                Divider()
                Button("Check Access…") { accessCheckPresented = true }
                    .disabled(store.selectedResourceType == nil)
                Button("Effective RBAC…") { effectiveRBACPresented = true }
                Button("Pulse…") { pulsePresented = true }
                Button("Helm Releases") { Task { await store.openHelmReleases() } }
                Button("Active Port Forwards…") { portForwardListPresented = true }
                Button("Host SSH…") { hostSSHPresented = true }
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
            ImageScanSettingsSection()
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
