import AppKit
import SwiftUI

struct ResourceInspectorView: View {
    @Environment(ClusterStore.self) private var store
    @Environment(\.accessibilityReduceMotion) private var accessibilityReduceMotion
    let resource: ResourceSummary?
    let type: ResourceType?
    let events: [ClusterEvent]
    let isPresented: Bool
    let presentationGeneration: Int
    @State private var section: InspectorSection = .overview
    @State private var isLoadingEvents = false
    @State private var overviewDetailsResourceID: ResourceSummary.ID?
    @State private var overviewPreparationTask: Task<Void, Never>?
    @State private var handledPresentationGeneration = 0

    /// The raw-object viewer can be revisited many times while a watch is
    /// updating the resource list. Keep the expensive JSON serialization out
    /// of those unrelated observer passes, while still invalidating it for a
    /// new Kubernetes resource version.
    private static let rawJSONCache: NSCache<NSString, NSString> = {
        let cache = NSCache<NSString, NSString>()
        cache.countLimit = 24
        return cache
    }()

    enum InspectorSection: String, CaseIterable, Identifiable { case overview = "Overview", events = "Events", raw = "Raw JSON", metadata = "Metadata"; var id: String { rawValue } }

    var body: some View {
        Group {
            if let resource {
                VStack(spacing: 0) {
                    inspectorHeader(resource)
                    Divider()
                    Picker("Inspector section", selection: $section) { ForEach(InspectorSection.allCases) { Text($0.rawValue).tag($0) } }
                        .pickerStyle(.segmented)
                        .labelsHidden()
                        .accessibilityLabel("Inspector section")
                        .padding(.horizontal, 14)
                        .padding(.vertical, 10)
                    Divider()
                    Group {
                        switch section {
                        case .overview:
                            overview(resource)
                        case .events:
                            ScrollView { eventList }
                        case .raw:
                            rawJSON(resource)
                        case .metadata:
                            metadata(resource)
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .navigationTitle(resource.name)
            } else {
                ContentUnavailableView("No Selection", systemImage: "sidebar.right", description: Text("Select a \(type?.kind ?? "resource") to inspect its status, metadata, and raw Kubernetes object."))
            }
        }
        .task(id: "\(isPresented)-\(resource?.id ?? "")-\(section.rawValue)") {
            // Event polling is valuable while reading the timeline but wastes
            // API capacity (and triggers needless view updates) on Overview,
            // Raw JSON, and Metadata.
            guard isPresented, section == .events, let resource else {
                isLoadingEvents = false
                return
            }
            isLoadingEvents = true
            await store.loadEvents(for: resource)
            guard !Task.isCancelled else { return }
            isLoadingEvents = false
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(5))
                guard !Task.isCancelled else { return }
                await store.loadEvents(for: resource)
            }
        }
        .onChange(of: resource?.id, initial: true) { _, resourceID in
            prepareOverviewForSelection(resourceID)
        }
        .onChange(of: presentationGeneration, initial: true) { _, generation in
            handleInspectorReveal(generation: generation)
        }
        .onChange(of: isPresented) { _, isPresented in
            guard !isPresented else { return }
            overviewPreparationTask?.cancel()
            overviewPreparationTask = nil
        }
        .onChange(of: accessibilityReduceMotion) { _, reduceMotion in
            guard reduceMotion, isPresented, let resourceID = resource?.id else { return }
            overviewPreparationTask?.cancel()
            overviewPreparationTask = nil
            setOverviewDetailsResourceID(resourceID)
            handledPresentationGeneration = presentationGeneration
        }
        .onDisappear {
            overviewPreparationTask?.cancel()
            overviewPreparationTask = nil
        }
    }

    private func inspectorHeader(_ resource: ResourceSummary) -> some View {
        HStack(spacing: 10) {
            Image(systemName: symbol(for: resource.kind))
                .foregroundStyle(.secondary)
                .frame(width: 22, height: 22)
            VStack(alignment: .leading, spacing: 2) {
                Text(resource.name).font(.headline).lineLimit(1)
                Text(resource.namespace?.isEmpty == false ? "\(resource.kind) · \(resource.namespace!)" : resource.kind)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .layoutPriority(1)
            Spacer(minLength: 8)
            Text(resource.status)
                .font(.caption.weight(.medium))
                .foregroundStyle(statusColor(resource.status))
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(maxWidth: 104, alignment: .trailing)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(resource.kind) \(resource.name), \(resource.namespace?.isEmpty == false ? "namespace \(resource.namespace!)" : "cluster-scoped"), status \(resource.status)")
    }

    @ViewBuilder private var eventList: some View {
        if isLoadingEvents && events.isEmpty {
            ProgressView("Loading events…")
                .controlSize(.small)
                .frame(maxWidth: .infinity, minHeight: 140, alignment: .top)
                .padding(.top, 32)
                .accessibilityLabel("Loading Kubernetes events")
        } else if events.isEmpty {
            ContentUnavailableView("No Events", systemImage: "bell.slash", description: Text("There are no Kubernetes events for this resource."))
                .padding(.top, 48)
        } else {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(events) { event in
                    VStack(alignment: .leading, spacing: 5) {
                        HStack { Text(event.type).font(.caption).fontWeight(.semibold).foregroundStyle(event.type == "Warning" ? .orange : .secondary); Text(event.reason).fontWeight(.medium); Spacer(); Text(event.lastSeen.formatted(date: .omitted, time: .shortened)).font(.caption).foregroundStyle(.secondary) }
                        Text(event.message).font(.callout).textSelection(.enabled)
                        if event.count > 1 { Text("Count: \(event.count)").font(.caption).foregroundStyle(.secondary) }
                    }
                    .padding()
                    Divider()
                }
            }
        }
    }

    @ViewBuilder private func overview(_ resource: ResourceSummary) -> some View {
        Form {
            resourceSummary(resource)
            if overviewDetailsResourceID == resource.id {
                schemaFreeDetails(resource, type: type)
                if let access = store.deleteAccess {
                    Section("Access") {
                        LabeledContent("Delete", value: access.allowed ? "Allowed" : "Not allowed")
                        if let reason = access.reason, !reason.isEmpty {
                            Text(reason).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                        }
                    }
                } else if store.isCheckingDeleteAccess {
                    Section("Access") { LabeledContent("Delete") { ProgressView().controlSize(.small) } }
                }
                metrics(resource)
                podDetails(resource)
                serviceDetails(resource)
                nodeDetails(resource)
                configurationDetails(resource)
                rolloutDetails(resource)
                if let type, ["deployments", "statefulsets", "daemonsets", "replicasets"].contains(type.resource), resource.namespace?.isEmpty == false {
                    RolloutHistorySection(resource: resource, type: type)
                }
                rbacDetails(resource)
                if resource.labels?["owner"] == "helm", let release = helmReleaseName(resource), let namespace = resource.namespace, !namespace.isEmpty {
                    HelmReleaseHistorySection(release: release, namespace: namespace)
                }
                if let labels = resource.labels, !labels.isEmpty {
                    Section("Labels") { ForEach(labels.sorted(by: { $0.key < $1.key }), id: \.key) { key, value in LabeledContent(key, value: value).textSelection(.enabled) } }
                }
            } else {
                Section("Details") {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text("Preparing resource details…")
                            .foregroundStyle(.secondary)
                    }
                    .accessibilityLabel("Preparing resource details")
                }
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
    }

    @ViewBuilder private func resourceSummary(_ resource: ResourceSummary) -> some View {
        Section("Resource") {
            LabeledContent("Kind", value: resource.kind)
            LabeledContent("Name", value: resource.name)
            LabeledContent("Namespace", value: resource.namespace ?? "Cluster-scoped")
            LabeledContent("Status", value: resource.status)
            LabeledContent("Age", value: resource.age)
        }
    }

    private func setOverviewDetailsResourceID(_ value: ResourceSummary.ID?) {
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            overviewDetailsResourceID = value
        }
    }

    /// Row selection while the inspector is already visible should feel
    /// instantaneous. If selection changes while it is hidden, avoid building
    /// an off-screen Form; the actual reveal path below will prepare it.
    private func prepareOverviewForSelection(_ resourceID: ResourceSummary.ID?) {
        overviewPreparationTask?.cancel()
        overviewPreparationTask = nil
        guard let resourceID else {
            setOverviewDetailsResourceID(nil)
            return
        }
        if isPresented {
            if handledPresentationGeneration < presentationGeneration {
                // A row can change during the short reveal handoff. Replace
                // the cancelled preparation with one for the new resource so
                // the inspector cannot remain on its Preparing state.
                handleInspectorReveal(generation: presentationGeneration)
            } else {
                setOverviewDetailsResourceID(resourceID)
            }
        } else if overviewDetailsResourceID != resourceID {
            setOverviewDetailsResourceID(nil)
        }
    }

    /// Defer the large detail tree only for a real hidden-to-visible system
    /// inspector transition. A prepared resource survives hide/reveal, and
    /// Reduce Motion skips the delay because the system transition is reduced.
    private func handleInspectorReveal(generation: Int) {
        overviewPreparationTask?.cancel()
        overviewPreparationTask = nil
        guard generation > handledPresentationGeneration, isPresented else { return }
        guard let resourceID = resource?.id else {
            // Revealing an empty inspector completes the handoff. A later
            // selection occurs in an already-visible surface and should
            // prepare immediately rather than inheriting a stale generation.
            handledPresentationGeneration = generation
            return
        }

        guard overviewDetailsResourceID != resourceID else {
            handledPresentationGeneration = generation
            return
        }

        guard !accessibilityReduceMotion else {
            setOverviewDetailsResourceID(resourceID)
            handledPresentationGeneration = generation
            return
        }

        overviewPreparationTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(260))
            guard !Task.isCancelled,
                  self.isPresented,
                  self.presentationGeneration == generation,
                  self.resource?.id == resourceID else { return }
            setOverviewDetailsResourceID(resourceID)
            handledPresentationGeneration = generation
            overviewPreparationTask = nil
        }
    }

    @ViewBuilder private func metrics(_ resource: ResourceSummary) -> some View {
        if let metrics = store.resourceMetrics, metrics.name == resource.name, metrics.namespace == resource.namespace {
            Section("Metrics") {
                LabeledContent("CPU", value: metrics.usage["cpu"] ?? "—")
                LabeledContent("Memory", value: metrics.usage["memory"] ?? "—")
                LabeledContent("Sample", value: metrics.timestamp.formatted(date: .omitted, time: .standard))
                if !metrics.window.isEmpty { LabeledContent("Window", value: metrics.window) }
                if !metrics.containers.isEmpty {
                    ForEach(metrics.containers) { container in
                        LabeledContent(container.name, value: "CPU \(container.usage["cpu"] ?? "—") · Memory \(container.usage["memory"] ?? "—")")
                    }
                }
                Button("Open in Pulse…") { store.openPulseDrilldown(for: resource) }
                    .accessibilityHint("Shows this \(resource.kind)'s metrics in the bounded cluster Pulse view")
                Button("Refresh Usage") { Task { await store.loadMetrics(for: resource) } }
            }
        } else if store.isLoadingMetrics, resource.kind == "Pod" || resource.kind == "Node" {
            Section("Metrics") { LabeledContent("Usage") { ProgressView().controlSize(.small) } }
        } else if let message = store.metricsUnavailableMessage, resource.kind == "Pod" || resource.kind == "Node" {
            Section("Metrics") {
                LabeledContent("Usage", value: "Unavailable")
                Text(message).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                Button("Open Pulse Diagnostics…") { store.openPulseDrilldown(for: resource) }
                Button("Retry Metrics") { Task { await store.loadMetrics(for: resource) } }
            }
        }
    }

    @ViewBuilder private func schemaFreeDetails(_ resource: ResourceSummary, type: ResourceType?) -> some View {
        // Avoid duplicating the dedicated Pod/Service/Node/workload/RBAC
        // inspectors. Everything else, including arbitrary CRDs, is rendered
        // only from structural Kubernetes conventions rather than a guessed
        // OpenAPI schema or custom resource fields.
        let specialisedKinds: Set<String> = ["Pod", "Service", "Node", "Deployment", "StatefulSet", "DaemonSet", "ReplicaSet", "ReplicationController", "Job", "CronJob", "ConfigMap", "Secret", "Role", "ClusterRole", "RoleBinding", "ClusterRoleBinding", "ServiceAccount"]
        if !specialisedKinds.contains(resource.kind), let raw = resource.raw?.objectValue {
        let metadata = raw["metadata"]?.objectValue ?? [:]
        let spec = raw["spec"]?.objectValue ?? [:]
        let status = raw["status"]?.objectValue ?? [:]
        Section("Resource Identity") {
            if let type { LabeledContent("Resource", value: type.gvr) }
            LabeledContent("API Version", value: resource.apiVersion)
            LabeledContent("Scope", value: resource.namespace?.isEmpty == false ? "Namespaced" : "Cluster-scoped")
            if let generation = metadata["generation"]?.intValue { LabeledContent("Generation", value: "\(generation)") }
            if let observed = status["observedGeneration"]?.intValue { LabeledContent("Observed generation", value: "\(observed)") }
            if !spec.isEmpty { LabeledContent("Spec fields", value: "\(spec.count)") }
            if !status.isEmpty { LabeledContent("Status fields", value: "\(status.count)") }
        }
        let conditions = status["conditions"]?.arrayValue ?? []
        if !conditions.isEmpty {
            Section("Conditions") {
                ForEach(Array(conditions.enumerated()), id: \.offset) { _, condition in
                    if let value = condition.objectValue, let conditionType = value["type"]?.stringValue {
                        VStack(alignment: .leading, spacing: 2) {
                            LabeledContent(conditionType, value: value["status"]?.stringValue ?? "Unknown")
                            if let reason = value["reason"]?.stringValue, !reason.isEmpty { Text(reason).font(.caption).foregroundStyle(.secondary) }
                            if let message = value["message"]?.stringValue, !message.isEmpty { Text(message).font(.caption).foregroundStyle(.secondary).textSelection(.enabled) }
                            if let transition = value["lastTransitionTime"]?.stringValue, !transition.isEmpty { Text("Last transition: \(transition)").font(.caption2).foregroundStyle(.tertiary) }
                        }
                    }
                }
            }
        }
        }
    }

    @ViewBuilder private func podDetails(_ resource: ResourceSummary) -> some View {
        if resource.kind == "Pod", let raw = resource.raw?.objectValue {
        let spec = raw["spec"]?.objectValue ?? [:]
        let status = raw["status"]?.objectValue ?? [:]
        Section("Pod") {
            if let node = spec["nodeName"]?.stringValue { LabeledContent("Node", value: node) }
            if let serviceAccount = spec["serviceAccountName"]?.stringValue { LabeledContent("Service account", value: serviceAccount) }
            if let podIP = status["podIP"]?.stringValue { LabeledContent("Pod IP", value: podIP) }
            if let hostIP = status["hostIP"]?.stringValue { LabeledContent("Host IP", value: hostIP) }
            if let qos = status["qosClass"]?.stringValue { LabeledContent("QoS class", value: qos) }
            if let policy = spec["restartPolicy"]?.stringValue { LabeledContent("Restart policy", value: policy) }
        }
        let statuses = status["containerStatuses"]?.arrayValue ?? []
        let initStatuses = status["initContainerStatuses"]?.arrayValue ?? []
        let containers = spec["containers"]?.arrayValue ?? []
        if !containers.isEmpty || !initStatuses.isEmpty {
            Section("Containers") {
                ForEach(Array(containers.enumerated()), id: \.offset) { _, container in
                    if let value = container.objectValue {
                        let name = value["name"]?.stringValue ?? "Container"
                        let runtime = statuses.first { $0.objectValue?["name"]?.stringValue == name }?.objectValue
                        VStack(alignment: .leading, spacing: 3) {
                            HStack {
                                Text(name).fontWeight(.medium)
                                Spacer()
                                let ready = runtime?["ready"]?.boolValue
                                if let ready {
                                    Label(ready ? "Ready" : "Not ready", systemImage: ready ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                                        .font(.caption)
                                        .foregroundStyle(ready ? .green : .orange)
                                }
                            }
                            Text(value["image"]?.stringValue ?? "—").font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                            if let restarts = runtime?["restartCount"]?.intValue { Text("Restarts: \(restarts)").font(.caption).foregroundStyle(.secondary) }
                            if let state = containerState(runtime) { Text(state).font(.caption).foregroundStyle(.secondary).textSelection(.enabled) }
                        }
                    }
                }
                if !initStatuses.isEmpty {
                    Divider()
                    Text("Init containers").font(.caption).foregroundStyle(.secondary)
                    ForEach(Array(initStatuses.enumerated()), id: \.offset) { _, container in
                        if let value = container.objectValue {
                            LabeledContent(value["name"]?.stringValue ?? "Init container", value: containerState(value) ?? "Completed status unavailable")
                        }
                    }
                }
            }
        }
        let conditions = status["conditions"]?.arrayValue ?? []
        if !conditions.isEmpty {
            Section("Conditions") {
                ForEach(Array(conditions.enumerated()), id: \.offset) { _, condition in
                    if let value = condition.objectValue, let type = value["type"]?.stringValue {
                        LabeledContent(type, value: value["status"]?.stringValue ?? "Unknown")
                    }
                }
            }
        }
        }
    }

    @ViewBuilder private func serviceDetails(_ resource: ResourceSummary) -> some View {
        if resource.kind == "Service", let raw = resource.raw?.objectValue {
        let spec = raw["spec"]?.objectValue ?? [:]
        let status = raw["status"]?.objectValue ?? [:]
        Section("Service") {
            LabeledContent("Type", value: spec["type"]?.stringValue ?? "ClusterIP")
            if let clusterIP = spec["clusterIP"]?.stringValue { LabeledContent("Cluster IP", value: clusterIP) }
            let clusterIPs = spec["clusterIPs"]?.arrayValue?.compactMap(\.stringValue) ?? []
            if clusterIPs.count > 1 { LabeledContent("Cluster IPs", value: clusterIPs.joined(separator: ", ")) }
            if let external = spec["externalName"]?.stringValue, !external.isEmpty { LabeledContent("External name", value: external) }
            if let affinity = spec["sessionAffinity"]?.stringValue { LabeledContent("Session affinity", value: affinity) }
            let selector = spec["selector"]?.objectValue ?? [:]
            if !selector.isEmpty { LabeledContent("Selector", value: selector.keys.sorted().map { "\($0)=\(selector[$0]?.stringValue ?? "")" }.joined(separator: ", ")) }
        }
        let ports = spec["ports"]?.arrayValue ?? []
        if !ports.isEmpty {
            Section("Ports") {
                ForEach(Array(ports.enumerated()), id: \.offset) { _, port in
                    if let value = port.objectValue {
                        let name = value["name"]?.stringValue
                        let number = value["port"]?.intValue.map(String.init) ?? "—"
                        let target = scalar(value["targetPort"]) ?? number
                        let nodePort = value["nodePort"]?.intValue.map { " · node \($0)" } ?? ""
                        LabeledContent(name ?? "Port \(number)", value: "\(value["protocol"]?.stringValue ?? "TCP") \(number) → \(target)\(nodePort)")
                    }
                }
            }
        }
        let ingress = status["loadBalancer"]?.objectValue?["ingress"]?.arrayValue ?? []
        let endpoints = ingress.compactMap { $0.objectValue?["ip"]?.stringValue ?? $0.objectValue?["hostname"]?.stringValue }
        if !endpoints.isEmpty { Section("Load Balancer") { LabeledContent("Ingress", value: endpoints.joined(separator: ", ")).textSelection(.enabled) } }
        }
    }

    @ViewBuilder private func nodeDetails(_ resource: ResourceSummary) -> some View {
        if resource.kind == "Node", let raw = resource.raw?.objectValue {
        let spec = raw["spec"]?.objectValue ?? [:]
        let status = raw["status"]?.objectValue ?? [:]
        Section("Scheduling") {
            LabeledContent("Scheduling", value: spec["unschedulable"]?.boolValue == true ? "Cordoned" : "Schedulable")
            if let podCIDR = spec["podCIDR"]?.stringValue, !podCIDR.isEmpty { LabeledContent("Pod CIDR", value: podCIDR) }
            let taints = spec["taints"]?.arrayValue ?? []
            if !taints.isEmpty { LabeledContent("Taints", value: taints.compactMap { taintSummary($0.objectValue) }.joined(separator: ", ")).textSelection(.enabled) }
        }
        let addresses = status["addresses"]?.arrayValue ?? []
        if !addresses.isEmpty {
            Section("Addresses") {
                ForEach(Array(addresses.enumerated()), id: \.offset) { _, address in
                    if let value = address.objectValue { LabeledContent(value["type"]?.stringValue ?? "Address", value: value["address"]?.stringValue ?? "—").textSelection(.enabled) }
                }
            }
        }
        let info = status["nodeInfo"]?.objectValue ?? [:]
        if !info.isEmpty {
            Section("System") {
                if let version = info["kubeletVersion"]?.stringValue { LabeledContent("Kubelet", value: version) }
                if let runtime = info["containerRuntimeVersion"]?.stringValue { LabeledContent("Container runtime", value: runtime) }
                if let os = info["osImage"]?.stringValue { LabeledContent("OS image", value: os) }
                if let kernel = info["kernelVersion"]?.stringValue { LabeledContent("Kernel", value: kernel) }
                if let architecture = info["architecture"]?.stringValue { LabeledContent("Architecture", value: architecture) }
            }
        }
        let conditions = status["conditions"]?.arrayValue ?? []
        if !conditions.isEmpty {
            Section("Conditions") {
                ForEach(Array(conditions.enumerated()), id: \.offset) { _, condition in
                    if let value = condition.objectValue, let type = value["type"]?.stringValue { LabeledContent(type, value: value["status"]?.stringValue ?? "Unknown") }
                }
            }
        }
        }
    }

    @ViewBuilder private func configurationDetails(_ resource: ResourceSummary) -> some View {
        if ["ConfigMap", "Secret"].contains(resource.kind), let raw = resource.raw?.objectValue {
        let data = raw["data"]?.objectValue ?? [:]
        let binaryData = raw["binaryData"]?.objectValue ?? [:]
        if resource.kind == "ConfigMap" {
            Section("ConfigMap Data") {
                LabeledContent("Entries", value: "\(data.count + binaryData.count)")
                if raw["immutable"]?.boolValue == true { LabeledContent("Immutable", value: "Yes") }
                ForEach(Array(data.keys.sorted().prefix(100)), id: \.self) { key in
                    LabeledContent(key, value: "\(data[key]?.stringValue?.count ?? 0) characters").textSelection(.enabled)
                }
                if data.count > 100 { Text("Showing the first 100 keys.").font(.caption).foregroundStyle(.secondary) }
            }
        } else {
            Section("Secret") {
                LabeledContent("Type", value: raw["type"]?.stringValue ?? "Opaque")
                LabeledContent("Data keys", value: "\(data.count + binaryData.count)")
                if raw["immutable"]?.boolValue == true { LabeledContent("Immutable", value: "Yes") }
                // Never decode or display Secret values here. The key names and
                // encoded lengths are useful operationally without widening
                // accidental disclosure in the normal inspector overview.
                ForEach(Array(data.keys.sorted().prefix(100)), id: \.self) { key in
                    LabeledContent(key, value: "\(data[key]?.stringValue?.count ?? 0) encoded characters").textSelection(.enabled)
                }
                if data.count > 100 { Text("Showing the first 100 keys.").font(.caption).foregroundStyle(.secondary) }
            }
        }
        }
    }

    @ViewBuilder private func rbacDetails(_ resource: ResourceSummary) -> some View {
        if let raw = resource.raw?.objectValue {
            switch resource.kind {
        case "Role", "ClusterRole":
            let rules = raw["rules"]?.arrayValue ?? []
            if rules.isEmpty {
                Section("RBAC Rules") { Text("This role has no rules.").foregroundStyle(.secondary) }
            } else {
                Section("RBAC Rules") {
                    ForEach(Array(rules.enumerated()), id: \.offset) { index, rule in
                        if let object = rule.objectValue {
                            VStack(alignment: .leading, spacing: 3) {
                                Text(ruleSummary(object)).font(.callout).fontWeight(.medium)
                                Text("API groups: \(list(object["apiGroups"], fallback: "core"))")
                                Text("Resources: \(list(object["resources"], fallback: "non-resource URL"))")
                                if let names = object["resourceNames"], !list(names).isEmpty { Text("Names: \(list(names))") }
                            }
                            .font(.caption)
                            .textSelection(.enabled)
                            if index < rules.count - 1 { Divider() }
                        }
                    }
                }
            }
        case "RoleBinding", "ClusterRoleBinding":
            Section("Role Reference") {
                let roleRef = raw["roleRef"]?.objectValue ?? [:]
                LabeledContent("Kind", value: roleRef["kind"]?.stringValue ?? "—")
                LabeledContent("Name", value: roleRef["name"]?.stringValue ?? "—")
                LabeledContent("API group", value: roleRef["apiGroup"]?.stringValue ?? "rbac.authorization.k8s.io")
            }
            let subjects = raw["subjects"]?.arrayValue ?? []
            Section("Subjects") {
                if subjects.isEmpty {
                    Text("No subjects are bound.").foregroundStyle(.secondary)
                } else {
                    ForEach(Array(subjects.enumerated()), id: \.offset) { _, subject in
                        if let object = subject.objectValue {
                            HStack {
                                Text(object["kind"]?.stringValue ?? "Subject").font(.caption).foregroundStyle(.secondary)
                                Text(object["name"]?.stringValue ?? "—")
                                if let namespace = object["namespace"]?.stringValue, !namespace.isEmpty { Text(namespace).font(.caption).foregroundStyle(.secondary) }
                            }
                            .textSelection(.enabled)
                        }
                    }
                }
            }
        case "ServiceAccount":
            Section("Service Account") {
                LabeledContent("Automount token", value: raw["automountServiceAccountToken"]?.boolValue == false ? "Disabled" : "Default")
                let pullSecrets = raw["imagePullSecrets"]?.arrayValue?.compactMap { $0.objectValue?["name"]?.stringValue } ?? []
                if !pullSecrets.isEmpty { LabeledContent("Image pull secrets", value: pullSecrets.joined(separator: ", ")) }
            }
            default:
                EmptyView()
            }
        }
    }

    @ViewBuilder private func rolloutDetails(_ resource: ResourceSummary) -> some View {
        if ["Deployment", "StatefulSet", "DaemonSet", "ReplicaSet", "ReplicationController"].contains(resource.kind),
           let object = resource.raw?.objectValue,
           let status = object["status"]?.objectValue {
        let desired = object["spec"]?.objectValue?["replicas"]?.intValue
        let ready = status["readyReplicas"]?.intValue ?? 0
        let updated = status["updatedReplicas"]?.intValue ?? 0
        let available = status["availableReplicas"]?.intValue ?? 0
        let unavailable = status["unavailableReplicas"]?.intValue ?? 0
        let desiredNodes = status["desiredNumberScheduled"]?.intValue ?? 0
        let daemonSetHealthy = desiredNodes > 0 && (status["numberAvailable"]?.intValue ?? 0) >= desiredNodes && (status["updatedNumberScheduled"]?.intValue ?? 0) >= desiredNodes
        let replicaWorkloadHealthy = desired != nil && desired == ready && desired == updated && unavailable == 0
        let isComplete = resource.kind == "DaemonSet" ? daemonSetHealthy : replicaWorkloadHealthy
        Section("Rollout") {
            HStack {
                Label(isComplete ? "Healthy" : "Progressing", systemImage: isComplete ? "checkmark.circle.fill" : "arrow.triangle.2.circlepath.circle.fill")
                    .foregroundStyle(isComplete ? .green : .orange)
                    .fontWeight(.medium)
                Spacer()
                if let desired { Text("Desired \(desired)").foregroundStyle(.secondary) }
            }
            if resource.kind == "DaemonSet" {
                LabeledContent("Scheduled", value: "\(status["currentNumberScheduled"]?.intValue ?? 0) current · \(status["desiredNumberScheduled"]?.intValue ?? 0) desired")
                LabeledContent("Updated", value: "\(status["updatedNumberScheduled"]?.intValue ?? 0)")
                LabeledContent("Available", value: "\(status["numberAvailable"]?.intValue ?? 0)")
            } else {
                LabeledContent("Ready", value: "\(ready)")
                LabeledContent("Updated", value: "\(updated)")
                LabeledContent("Available", value: "\(available)")
                if unavailable > 0 { LabeledContent("Unavailable", value: "\(unavailable)") }
            }
            if let revision = status["currentRevision"]?.stringValue { LabeledContent("Current revision", value: revision) }
            if let revision = status["updateRevision"]?.stringValue, revision != status["currentRevision"]?.stringValue { LabeledContent("Update revision", value: revision) }
            let conditions = status["conditions"]?.arrayValue ?? []
            ForEach(Array(conditions.enumerated()), id: \.offset) { _, condition in
                if let value = condition.objectValue,
                   let type = value["type"]?.stringValue,
                   let conditionStatus = value["status"]?.stringValue {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("\(type): \(conditionStatus)").font(.caption).fontWeight(.medium)
                        if let reason = value["reason"]?.stringValue, !reason.isEmpty { Text(reason).font(.caption).foregroundStyle(.secondary) }
                        if let message = value["message"]?.stringValue, !message.isEmpty { Text(message).font(.caption).foregroundStyle(.secondary).textSelection(.enabled) }
                    }
                }
            }
        }
        }
    }

    @ViewBuilder private func metadata(_ resource: ResourceSummary) -> some View {
        Form {
            Section("Identity") {
                LabeledContent("Kind", value: resource.kind)
                LabeledContent("Name", value: resource.name).textSelection(.enabled)
                LabeledContent("Namespace", value: resource.namespace ?? "Cluster-scoped")
                LabeledContent("UID", value: resource.uid).textSelection(.enabled)
                LabeledContent("API Version", value: resource.apiVersion)
            }
            Section("Lifecycle") {
                LabeledContent("Created", value: resource.createdAt.formatted(date: .abbreviated, time: .shortened))
                LabeledContent("Age", value: resource.age)
            }
            if let metadata = resource.raw?.objectValue?["metadata"]?.objectValue {
                let annotations = metadata["annotations"]?.objectValue ?? [:]
                if !annotations.isEmpty {
                    Section("Annotations") {
                        ForEach(annotations.sorted(by: { $0.key < $1.key }), id: \.key) { key, value in
                            LabeledContent(key, value: value.stringValue ?? "—").textSelection(.enabled)
                        }
                    }
                }
                let owners = metadata["ownerReferences"]?.arrayValue ?? []
                if !owners.isEmpty {
                    Section("Owners") {
                        ForEach(Array(owners.enumerated()), id: \.offset) { _, owner in
                            if let value = owner.objectValue {
                                LabeledContent(value["kind"]?.stringValue ?? "Owner", value: value["name"]?.stringValue ?? "—")
                                    .textSelection(.enabled)
                            }
                        }
                    }
                }
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
    }

    @ViewBuilder private func rawJSON(_ resource: ResourceSummary) -> some View {
        let source = prettyJSON(resource)
        VStack(spacing: 0) {
            HStack {
                Text("Sorted, API-faithful object JSON")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Copy JSON") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(source, forType: .string)
                }
                .help("Copy the full Kubernetes object as sorted JSON")
                .accessibilityHint("Copies the full Kubernetes object as sorted JSON")
            }
            .padding(.horizontal)
            .padding(.vertical, 10)
            Divider()
            SyntaxHighlightedTextView(source: source, language: .json)
                .accessibilityLabel("Raw JSON for \(resource.kind) \(resource.name)")
        }
        .frame(maxWidth: .infinity, minHeight: 300, maxHeight: .infinity, alignment: .topLeading)
    }

    private func prettyJSON(_ resource: ResourceSummary) -> String {
        let cacheKey = "\(resource.id)|\(resource.resourceVersion ?? "")|\(resource.raw == nil ? "summary" : "raw")" as NSString
        if let cached = Self.rawJSONCache.object(forKey: cacheKey) {
            return cached as String
        }
        let raw = resource.raw
        guard let raw, let data = try? JSONEncoder().encode(raw), let value = try? JSONSerialization.jsonObject(with: data), let pretty = try? JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys]) else { return "No raw object available." }
        let formatted = String(decoding: pretty, as: UTF8.self)
        Self.rawJSONCache.setObject(formatted as NSString, forKey: cacheKey)
        return formatted
    }

    private func list(_ value: JSONValue?, fallback: String = "") -> String {
        let values = value?.arrayValue?.compactMap(\.stringValue) ?? []
        return values.isEmpty ? fallback : values.joined(separator: ", ")
    }

    private func scalar(_ value: JSONValue?) -> String? {
        if let string = value?.stringValue { return string }
        if let number = value?.intValue { return String(number) }
        if let bool = value?.boolValue { return bool ? "true" : "false" }
        return nil
    }

    private func containerState(_ container: [String: JSONValue]?) -> String? {
        guard let state = container?["state"]?.objectValue else { return nil }
        if let waiting = state["waiting"]?.objectValue {
            let reason = waiting["reason"]?.stringValue ?? "Waiting"
            let message = waiting["message"]?.stringValue
            return message?.isEmpty == false ? "\(reason): \(message!)" : reason
        }
        if let terminated = state["terminated"]?.objectValue {
            let reason = terminated["reason"]?.stringValue ?? "Terminated"
            let code = terminated["exitCode"]?.intValue
            return code.map { "\(reason) (exit \($0))" } ?? reason
        }
        if state["running"] != nil { return "Running" }
        return nil
    }

    private func taintSummary(_ taint: [String: JSONValue]?) -> String? {
        guard let taint else { return nil }
        guard let key = taint["key"]?.stringValue else { return nil }
        let value = taint["value"]?.stringValue
        let effect = taint["effect"]?.stringValue ?? ""
        return "\(key)\(value?.isEmpty == false ? "=\(value!)" : "")\(effect.isEmpty ? "" : ":\(effect)")"
    }

    private func ruleSummary(_ rule: [String: JSONValue]) -> String {
        let verbs = list(rule["verbs"], fallback: "no verbs")
        if let urls = rule["nonResourceURLs"], !list(urls).isEmpty { return "\(verbs) · \(list(urls))" }
        return verbs
    }

    private func helmReleaseName(_ resource: ResourceSummary) -> String? {
        if let name = resource.labels?["name"], !name.isEmpty { return name }
        return resource.raw?.objectValue?["metadata"]?.objectValue?["annotations"]?.objectValue?["meta.helm.sh/release-name"]?.stringValue
    }

    private func statusColor(_ status: String) -> Color {
        switch status.lowercased() {
        case "running", "active", "bound", "ready", "healthy": .green
        case "failed", "error", "unknown", "notready": .red
        case "pending", "terminating", "progressing": .orange
        default: .secondary
        }
    }

    private func symbol(for kind: String) -> String {
        switch kind {
        case "Pod": "shippingbox"
        case "Deployment", "StatefulSet", "DaemonSet", "ReplicaSet", "Job", "CronJob": "cube.box"
        case "Service", "Ingress": "point.3.connected.trianglepath.dotted"
        case "Node": "server.rack"
        default: "cube"
        }
    }
}
