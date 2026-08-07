import Foundation
import Observation
import AppKit

@MainActor
@Observable
final class ClusterStore {
    var contexts: [KubeContext] = []
    var namespaces: [String] = ["All Namespaces"]
    var discoveredResources: [ResourceType] = []
    var selectedContext: KubeContext?
    var selectedNamespace = UserDefaults.standard.string(forKey: "k9k.selectedNamespace") ?? "All Namespaces" { didSet { UserDefaults.standard.set(selectedNamespace, forKey: "k9k.selectedNamespace") } }
    var selectedResourceType: ResourceType?
    var resources: [ResourceSummary] = []
    var selectedResources = Set<ResourceSummary.ID>()
    var searchText = ""
    var labelSelector = ""
    var errorMessage: String?
    var isLoading = false
    var isReadOnly = UserDefaults.standard.bool(forKey: "k9k.readOnly") { didSet { UserDefaults.standard.set(isReadOnly, forKey: "k9k.readOnly") } }
    var activeStreamID: String?
    var k9sAliases: [K9sAlias] = []
    var k9sConfig: K9sConfigSummary?
    var k9sConfigDocument: K9sConfigDocument?

    var events: [ClusterEvent] = []
    var logLines: [String] = []
    var activeLogStreamID: String?
    var activePortForward: PortForwardBinding?
    var activePortForwardStreamID: String?
    var activeExecStreamID: String?
    var execAccess: AccessReview?
    var isCheckingExecAccess = false
    var manifestAccess: AccessReview?
    var isCheckingManifestAccess = false
    var resourceMetrics: ResourceMetrics?
    var metricsUnavailableMessage: String?
    var isLoadingMetrics = false
    var deleteAccess: AccessReview?
    var isCheckingDeleteAccess = false
    var scaleAccess: AccessReview?
    var isCheckingScaleAccess = false
    var restartAccess: AccessReview?
    var isCheckingRestartAccess = false
    var nodePatchAccess: AccessReview?
    var relationshipGraph: RelationshipGraph?
    var isLoadingRelationships = false
    private var deleteAccessGeneration = 0
    private var scaleAccessGeneration = 0
    private var restartAccessGeneration = 0
    private var execAccessGeneration = 0
    private var manifestAccessGeneration = 0
    private var terminalOutputSink: ((Data) -> Void)?
    private var terminalColumns = 120
    private var terminalRows = 36
    private var watchReconnectAttempts = 0

    private let client = CoreClient()

    init() {
        client.onEvent = { [weak self] envelope in self?.apply(event: envelope) }
    }

    var visibleResources: [ResourceSummary] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !query.isEmpty else { return resources }
        return resources.filter { resource in
            resource.name.lowercased().contains(query) || resource.kind.lowercased().contains(query) || resource.namespace?.lowercased().contains(query) == true
        }
    }

    func connect() async {
        isLoading = true
        defer { isLoading = false }
        do {
            async let contextsEnvelope = client.request("context.list")
            async let discoveryEnvelope = client.request("discovery.list")
            contexts = try decodeArray((try await contextsEnvelope).result, as: KubeContext.self)
            selectedContext = contexts.first(where: \.active) ?? contexts.first
            discoveredResources = try decodeArray((try await discoveryEnvelope).result, as: ResourceType.self)
            await loadK9sConfig()
            ensureDefaultResourceSelection()
            await loadNamespaces()
            await loadResources()
        } catch { errorMessage = error.localizedDescription }
    }

    func selectContext(_ context: KubeContext) async {
        isLoading = true
        defer { isLoading = false }
        do {
            _ = try await client.request("context.select", parameters: .object(["name": .string(context.name)]))
            selectedContext = context
            contexts = contexts.map { KubeContext(name: $0.name, cluster: $0.cluster, user: $0.user, active: $0.id == context.id) }
            selectedNamespace = "All Namespaces"
            await loadNamespaces()
            await refreshDiscovery()
            await loadResources()
        } catch { errorMessage = error.localizedDescription }
    }

    func refreshDiscovery() async {
        do {
            discoveredResources = try decodeArray((try await client.request("discovery.list")).result, as: ResourceType.self)
            ensureDefaultResourceSelection()
        }
        catch { errorMessage = error.localizedDescription }
    }

    func loadNamespaces() async {
        do {
            namespaces = ["All Namespaces"] + (try decodeArray((try await client.request("namespace.list")).result, as: String.self))
            if !namespaces.contains(selectedNamespace) { selectedNamespace = "All Namespaces" }
        }
        catch { errorMessage = error.localizedDescription }
    }

    func loadK9sConfig() async {
        do {
            let config = try decode((try await client.request("config.summary")).result, as: K9sConfigSummary.self)
            k9sConfig = config
            k9sAliases = config.aliases
        } catch {
            // K9s configuration is optional compatibility metadata. It must
            // never prevent access to the selected Kubernetes context.
            k9sConfig = nil
            k9sAliases = []
        }
    }

    func loadK9sConfigDocument(named name: String) async {
        do { k9sConfigDocument = try decode((try await client.request("config.document", parameters: .object(["name": .string(name)])).result), as: K9sConfigDocument.self) }
        catch { k9sConfigDocument = nil; errorMessage = error.localizedDescription }
    }

    func saveK9sConfigDocument(_ document: K9sConfigDocument, content: String) async -> Bool {
        do {
            let result = try decode((try await client.request("config.write", parameters: .object(["name": .string(document.name), "expectedSHA256": .string(document.sha256), "content": .string(content), "confirm": .bool(true)])).result), as: K9sConfigDocument.self)
            k9sConfigDocument = result
            await loadK9sConfig()
            return true
        } catch { errorMessage = error.localizedDescription; return false }
    }

    func loadResources() async {
        guard let type = selectedResourceType else { return }
        if let activeStreamID { await client.cancel(streamID: activeStreamID) }
        isLoading = true
        defer { isLoading = false }
        do {
            let streamID = UUID().uuidString
            let namespace = selectedNamespace == "All Namespaces" ? "" : selectedNamespace
            var params = type.requestParameters.objectValue ?? [:]
            params["namespace"] = .string(namespace)
            params["selector"] = .string(labelSelector)
            params["streamID"] = .string(streamID)
            resources = try decodeArray((try await client.request("resource.list", parameters: .object(params))).result, as: ResourceSummary.self)
            watchReconnectAttempts = 0
            activeStreamID = streamID
            _ = try? await client.request("resource.watch", parameters: .object(params))
        } catch { errorMessage = error.localizedDescription }
    }

    func selectResourceType(_ type: ResourceType) async {
        selectedResourceType = type
        selectedResources.removeAll()
        deleteAccess = nil
        scaleAccess = nil
        restartAccess = nil
        execAccess = nil
        manifestAccess = nil
        relationshipGraph = nil
    }

    func openHelmReleases() async {
        guard let secrets = preferredResource(named: "secrets") else { return }
        selectedResourceType = secrets
        selectedResources.removeAll()
        labelSelector = "owner=helm"
        await loadResources()
    }

    func loadRelationships(for resource: ResourceSummary?, type: ResourceType?) async {
        guard let resource, let type else { relationshipGraph = nil; return }
        isLoadingRelationships = true
        defer { isLoadingRelationships = false }
        do {
            relationshipGraph = try decode(
                (try await client.request("relationships.get", parameters: operationParameters(type: type, resource: resource))).result,
                as: RelationshipGraph.self
            )
        } catch {
            relationshipGraph = nil
            errorMessage = error.localizedDescription
        }
    }

    func deleteSelected() async {
        guard !isReadOnly, let type = selectedResourceType else { return }
        await updateDeleteAccess()
        guard canDeleteSelected else {
            errorMessage = deleteAccess?.reason ?? "The active Kubernetes identity is not authorized to delete this resource."
            return
        }
        let selected = resources.filter { selectedResources.contains($0.id) }
        do {
            for resource in selected {
                _ = try await client.request("resource.delete", parameters: operationParameters(type: type, resource: resource, additional: ["confirm": .bool(true)]))
            }
            await loadResources()
        } catch { errorMessage = error.localizedDescription }
    }

    var canDeleteSelected: Bool {
        !isReadOnly && !selectedResources.isEmpty && deleteAccess?.allowed == true
    }

    var canScaleSelected: Bool {
        !isReadOnly && selectedResources.count == 1 && selectedScalableResource != nil && scaleAccess?.allowed == true
    }

    var isSelectedResourceScalable: Bool { selectedScalableResource != nil }

    var canRestartSelected: Bool {
        !isReadOnly && selectedRestartableResource != nil && restartAccess?.allowed == true
    }

    var isSelectedResourceRestartable: Bool { selectedRestartableResource != nil }

    var selectedNodeResource: ResourceSummary? { guard selectedResources.count == 1, let resource = selectedSelectedResource, resource.kind == "Node" else { return nil }; return resource }
    var canPatchSelectedNode: Bool { !isReadOnly && selectedNodeResource != nil && nodePatchAccess?.allowed == true }

    var canOpenExec: Bool {
        !isReadOnly && selectedPodResource != nil && execAccess?.allowed == true
    }

    var isSelectedResourcePod: Bool { selectedPodResource != nil }

    var canEditSelectedManifest: Bool {
        !isReadOnly && selectedResourceType != nil && selectedResources.count == 1 && manifestAccess?.allowed == true
    }

    var hasSelectedManifest: Bool { selectedResourceType != nil && selectedResources.count == 1 && selectedSelectedResource != nil }

    var selectedReplicaCount: Int {
        selectedScalableResource?.raw?.objectValue?["spec"]?.objectValue?["replicas"]?.intValue ?? 1
    }

    func updateDeleteAccess() async {
        deleteAccessGeneration &+= 1
        let generation = deleteAccessGeneration
        guard let type = selectedResourceType else {
            deleteAccess = nil
            isCheckingDeleteAccess = false
            return
        }
        let selected = resources.filter { selectedResources.contains($0.id) }
        guard !selected.isEmpty else {
            deleteAccess = nil
            isCheckingDeleteAccess = false
            return
        }

        isCheckingDeleteAccess = true
        defer {
            if generation == deleteAccessGeneration { isCheckingDeleteAccess = false }
        }
        do {
            var finalReview: AccessReview?
            for resource in selected {
                let review = try decode(
                    (try await client.request("rbac.check", parameters: operationParameters(type: type, resource: resource, additional: ["verb": .string("delete")]))).result,
                    as: AccessReview.self
                )
                finalReview = review
                if !review.allowed {
                    if generation == deleteAccessGeneration { deleteAccess = review }
                    return
                }
            }
            if generation == deleteAccessGeneration { deleteAccess = finalReview }
        } catch {
            if generation == deleteAccessGeneration {
                deleteAccess = AccessReview(allowed: false, denied: false, reason: "K9k could not verify delete permission: \(error.localizedDescription)", evaluationError: nil)
            }
        }
    }

    func updateScaleAccess() async {
        scaleAccessGeneration &+= 1
        let generation = scaleAccessGeneration
        guard let type = selectedResourceType, let resource = selectedScalableResource else {
            scaleAccess = nil
            isCheckingScaleAccess = false
            return
        }
        isCheckingScaleAccess = true
        defer {
            if generation == scaleAccessGeneration { isCheckingScaleAccess = false }
        }
        do {
            let review = try decode(
                (try await client.request("rbac.check", parameters: operationParameters(type: type, resource: resource, additional: ["verb": .string("patch")]))).result,
                as: AccessReview.self
            )
            if generation == scaleAccessGeneration { scaleAccess = review }
        } catch {
            if generation == scaleAccessGeneration {
                scaleAccess = AccessReview(allowed: false, denied: false, reason: "K9k could not verify scale permission: \(error.localizedDescription)", evaluationError: nil)
            }
        }
    }

    func scaleSelected(to replicas: Int) async {
        guard !isReadOnly, let type = selectedResourceType, let resource = selectedScalableResource else { return }
        guard replicas >= 0 else {
            errorMessage = "Replica count cannot be negative."
            return
        }
        await updateScaleAccess()
        guard canScaleSelected else {
            errorMessage = scaleAccess?.reason ?? "The active Kubernetes identity is not authorized to scale this workload."
            return
        }
        do {
            _ = try await client.request("resource.scale", parameters: operationParameters(type: type, resource: resource, additional: ["replicas": .number(Double(replicas))]))
            await loadResources()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func updateRestartAccess() async {
        restartAccessGeneration &+= 1
        let generation = restartAccessGeneration
        guard let type = selectedResourceType, let resource = selectedRestartableResource else {
            restartAccess = nil
            isCheckingRestartAccess = false
            return
        }
        isCheckingRestartAccess = true
        defer {
            if generation == restartAccessGeneration { isCheckingRestartAccess = false }
        }
        do {
            let review = try decode(
                (try await client.request("rbac.check", parameters: operationParameters(type: type, resource: resource, additional: ["verb": .string("patch")]))).result,
                as: AccessReview.self
            )
            if generation == restartAccessGeneration { restartAccess = review }
        } catch {
            if generation == restartAccessGeneration {
                restartAccess = AccessReview(allowed: false, denied: false, reason: "K9k could not verify restart permission: \(error.localizedDescription)", evaluationError: nil)
            }
        }
    }

    func restartSelected() async {
        guard !isReadOnly, let type = selectedResourceType, let resource = selectedRestartableResource else { return }
        await updateRestartAccess()
        guard canRestartSelected else {
            errorMessage = restartAccess?.reason ?? "The active Kubernetes identity is not authorized to restart this workload."
            return
        }
        let timestamp = ISO8601DateFormatter().string(from: Date())
        let patch: JSONValue = .object([
            "spec": .object([
                "template": .object([
                    "metadata": .object([
                        "annotations": .object(["kubectl.kubernetes.io/restartedAt": .string(timestamp)])
                    ])
                ])
            ])
        ])
        do {
            _ = try await client.request("resource.patch", parameters: operationParameters(type: type, resource: resource, additional: ["patch": patch]))
            await loadResources()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func updateNodePatchAccess() async {
        guard let type = selectedResourceType, let node = selectedNodeResource else { nodePatchAccess = nil; return }
        do { nodePatchAccess = try decode((try await client.request("rbac.check", parameters: operationParameters(type: type, resource: node, additional: ["verb": .string("patch")]))).result, as: AccessReview.self) }
        catch { nodePatchAccess = AccessReview(allowed: false, denied: false, reason: "K9k could not verify node patch permission: \(error.localizedDescription)", evaluationError: nil) }
    }

    func setSelectedNodeUnschedulable(_ unschedulable: Bool) async {
        guard let type = selectedResourceType, let node = selectedNodeResource, !isReadOnly else { return }
        await updateNodePatchAccess()
        guard canPatchSelectedNode else { errorMessage = nodePatchAccess?.reason ?? "The active Kubernetes identity is not authorized to cordon this node."; return }
        do {
            _ = try await client.request("resource.patch", parameters: operationParameters(type: type, resource: node, additional: ["patch": .object(["spec": .object(["unschedulable": .bool(unschedulable)])])]))
            await loadResources()
        } catch { errorMessage = error.localizedDescription }
    }

    func updateExecAccess() async {
        execAccessGeneration &+= 1
        let generation = execAccessGeneration
        guard let type = selectedResourceType, let resource = selectedPodResource else {
            execAccess = nil
            isCheckingExecAccess = false
            return
        }
        isCheckingExecAccess = true
        defer {
            if generation == execAccessGeneration { isCheckingExecAccess = false }
        }
        do {
            let parameters = operationParameters(type: type, resource: resource, additional: [
                "verb": .string("create"),
                "subresource": .string("exec")
            ])
            let review = try decode((try await client.request("rbac.check", parameters: parameters)).result, as: AccessReview.self)
            if generation == execAccessGeneration { execAccess = review }
        } catch {
            if generation == execAccessGeneration {
                execAccess = AccessReview(allowed: false, denied: false, reason: "K9k could not verify Pod exec permission: \(error.localizedDescription)", evaluationError: nil)
            }
        }
    }

    func openExec(for resource: ResourceSummary, command: [String], container: String? = nil) async {
        guard resource.kind == "Pod", let namespace = resource.namespace else { return }
        await updateExecAccess()
        guard canOpenExec else {
            errorMessage = execAccess?.reason ?? "The active Kubernetes identity is not authorized to open an exec session for this Pod."
            return
        }
        await closeExec()
        let streamID = UUID().uuidString
        activeExecStreamID = streamID
        var parameters: [String: JSONValue] = [
            "streamID": .string(streamID),
            "namespace": .string(namespace),
            "pod": .string(resource.name),
            "command": .array(command.map(JSONValue.string)),
            "tty": .bool(true),
            "stdin": .bool(true),
            "initialColumns": .number(Double(terminalColumns)),
            "initialRows": .number(Double(terminalRows))
        ]
        if let container, !container.isEmpty { parameters["container"] = .string(container) }
        do {
            _ = try await client.request("exec.open", parameters: .object(parameters))
        } catch {
            activeExecStreamID = nil
            errorMessage = error.localizedDescription
        }
    }

    func sendExecInput(_ input: String) async {
        await sendExecInput(Data(input.utf8))
    }

    func sendExecInput(_ data: Data) async {
        guard let activeExecStreamID, !data.isEmpty else { return }
        do {
            _ = try await client.request("exec.stdin", parameters: .object([
                "streamID": .string(activeExecStreamID),
                "dataBase64": .string(data.base64EncodedString())
            ]))
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func resizeExec(columns: Int, rows: Int) async {
        guard columns > 0, rows > 0 else { return }
        terminalColumns = columns
        terminalRows = rows
        guard let activeExecStreamID else { return }
        do {
            _ = try await client.request("exec.resize", parameters: .object([
                "streamID": .string(activeExecStreamID),
                "columns": .number(Double(columns)),
                "rows": .number(Double(rows))
            ]))
        } catch {
            // A resize can race normal session teardown. Surface all other
            // errors but do not fabricate a live terminal after it closes.
            if activeExecStreamID != nil { errorMessage = error.localizedDescription }
        }
    }

    func setTerminalOutputSink(_ sink: @escaping (Data) -> Void) {
        terminalOutputSink = sink
    }

    func clearTerminalOutputSink() {
        terminalOutputSink = nil
    }

    func closeExec() async {
        if let activeExecStreamID { await client.cancel(streamID: activeExecStreamID) }
        activeExecStreamID = nil
    }

    func updateManifestAccess() async {
        manifestAccessGeneration &+= 1
        let generation = manifestAccessGeneration
        guard let type = selectedResourceType, let resource = selectedSelectedResource else {
            manifestAccess = nil
            isCheckingManifestAccess = false
            return
        }
        isCheckingManifestAccess = true
        defer {
            if generation == manifestAccessGeneration { isCheckingManifestAccess = false }
        }
        do {
            let review = try decode(
                (try await client.request("rbac.check", parameters: operationParameters(type: type, resource: resource, additional: ["verb": .string("patch")]))).result,
                as: AccessReview.self
            )
            if generation == manifestAccessGeneration { manifestAccess = review }
        } catch {
            if generation == manifestAccessGeneration {
                manifestAccess = AccessReview(allowed: false, denied: false, reason: "K9k could not verify manifest edit permission: \(error.localizedDescription)", evaluationError: nil)
            }
        }
    }

    func fetchManifest(type: ResourceType, resource: ResourceSummary) async throws -> ManifestDocument {
        try decode((try await client.request("manifest.get", parameters: operationParameters(type: type, resource: resource))).result, as: ManifestDocument.self)
    }

    func validateManifest(type: ResourceType, document: ManifestDocument, source: String) async throws -> ManifestApplyResult {
        try await submitManifest(type: type, document: document, source: source, confirm: false)
    }

    func applyManifest(type: ResourceType, document: ManifestDocument, source: String) async throws -> ManifestApplyResult {
        try await submitManifest(type: type, document: document, source: source, confirm: true)
    }

    func copySelectedName() {
        guard let resource = resources.first(where: { selectedResources.contains($0.id) }) else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(resource.name, forType: .string)
    }

    func loadEvents(for resource: ResourceSummary?) async {
        guard let resource, let namespace = resource.namespace, !namespace.isEmpty else { events = []; return }
        do {
            events = try decodeArray((try await client.request("resource.events", parameters: .object(["namespace": .string(namespace), "uid": .string(resource.uid)]))).result, as: ClusterEvent.self)
        } catch { events = [] }
    }

    func loadMetrics(for resource: ResourceSummary?) async {
        resourceMetrics = nil
        metricsUnavailableMessage = nil
        guard let resource else { return }
        let metricResource: String
        switch resource.kind {
        case "Pod": metricResource = "pods"
        case "Node": metricResource = "nodes"
        default: return
        }
        isLoadingMetrics = true
        defer { isLoadingMetrics = false }
        var parameters: [String: JSONValue] = [
            "resource": .string(metricResource),
            "name": .string(resource.name)
        ]
        if metricResource == "pods", let namespace = resource.namespace {
            parameters["namespace"] = .string(namespace)
        }
        do {
            let response = try decode((try await client.request("metrics.list", parameters: .object(parameters))).result, as: MetricsListResponse.self)
            resourceMetrics = response.items.first
        } catch let error as CoreError where error.code == "metrics_unavailable" {
            metricsUnavailableMessage = error.message
        } catch {
            metricsUnavailableMessage = "K9k could not load metrics: \(error.localizedDescription)"
        }
    }

    func openLogs(for resource: ResourceSummary, container: String = "", previous: Bool = false, timestamps: Bool = true) async {
        guard resource.kind == "Pod", let namespace = resource.namespace else { return }
        if let activeLogStreamID { await client.cancel(streamID: activeLogStreamID) }
        let streamID = UUID().uuidString
        logLines = []
        activeLogStreamID = streamID
        do {
            _ = try await client.request("logs.open", parameters: .object([
                "streamID": .string(streamID), "namespace": .string(namespace), "pod": .string(resource.name), "container": .string(container), "previous": .bool(previous), "follow": .bool(true), "timestamps": .bool(timestamps), "tailLines": .number(500)
            ]))
        } catch { errorMessage = error.localizedDescription }
    }

    func closeLogs() async {
        if let activeLogStreamID { await client.cancel(streamID: activeLogStreamID) }
        activeLogStreamID = nil
    }

    func openPortForward(for resource: ResourceSummary, remotePort: Int, localPort: Int = 0) async {
        guard resource.kind == "Pod", let namespace = resource.namespace else { return }
        guard (1...65535).contains(remotePort), (0...65535).contains(localPort) else {
            errorMessage = "Ports must be between 1 and 65535 (or use 0 for an automatic local port)."
            return
        }
        await closePortForward()
        let streamID = UUID().uuidString
        do {
            let result = try await client.request("portforward.open", parameters: .object([
                "streamID": .string(streamID),
                "namespace": .string(namespace),
                "pod": .string(resource.name),
                "remotePort": .number(Double(remotePort)),
                "localPort": .number(Double(localPort)),
                "localAddress": .string("127.0.0.1")
            ]))
            activePortForward = try decode(result.result, as: PortForwardBinding.self)
            activePortForwardStreamID = streamID
        } catch {
            activePortForward = nil
            activePortForwardStreamID = nil
            errorMessage = error.localizedDescription
        }
    }

    func closePortForward() async {
        if let activePortForwardStreamID { await client.cancel(streamID: activePortForwardStreamID) }
        activePortForward = nil
        activePortForwardStreamID = nil
    }

    func resource(for id: ResourceSummary.ID?) -> ResourceSummary? { guard let id else { return nil }; return resources.first(where: { $0.id == id }) }

    private var selectedScalableResource: ResourceSummary? {
        guard let type = selectedResourceType,
              ["deployments", "statefulsets", "replicasets", "replicationcontrollers"].contains(type.resource),
              selectedResources.count == 1,
              let id = selectedResources.first else { return nil }
        return resource(for: id)
    }

    private var selectedRestartableResource: ResourceSummary? {
        guard let type = selectedResourceType,
              ["deployments", "statefulsets", "daemonsets"].contains(type.resource),
              selectedResources.count == 1,
              let id = selectedResources.first else { return nil }
        return resource(for: id)
    }

    private var selectedPodResource: ResourceSummary? {
        guard selectedResourceType?.resource == "pods",
              selectedResources.count == 1,
              let id = selectedResources.first,
              let resource = resource(for: id),
              resource.kind == "Pod" else { return nil }
        return resource
    }

    private var selectedSelectedResource: ResourceSummary? {
        guard selectedResources.count == 1, let id = selectedResources.first else { return nil }
        return resource(for: id)
    }

    func resourceType(forK9sAlias name: String) -> ResourceType? {
        var visited = Set<String>()
        func resolve(_ target: String) -> ResourceType? {
            let normalized = target.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            if let direct = discoveredResources.first(where: { type in
                type.resource.lowercased() == normalized || type.shortNames.map { $0.lowercased() }.contains(normalized) || type.gvr.lowercased() == normalized
            }) {
                return direct
            }
            guard visited.insert(normalized).inserted,
                  let alias = k9sAliases.first(where: { $0.name.lowercased() == normalized }) else { return nil }
            return resolve(alias.target)
        }
        return resolve(name)
    }

    func ensureDefaultResourceSelection() {
        guard selectedResourceType == nil || !discoveredResources.contains(selectedResourceType!) else { return }
        selectedResourceType = preferredResource(named: "pods") ?? discoveredResources.first
    }

    private func preferredResource(named name: String) -> ResourceType? { discoveredResources.first { $0.resource == name && $0.group.isEmpty } }
    private func operationParameters(type: ResourceType, resource: ResourceSummary, additional: [String: JSONValue] = [:]) -> JSONValue {
        var values = type.requestParameters.objectValue ?? [:]
        values["namespace"] = .string(resource.namespace ?? "")
        values["name"] = .string(resource.name)
        additional.forEach { values[$0.key] = $0.value }
        return .object(values)
    }

    private func submitManifest(type: ResourceType, document: ManifestDocument, source: String, confirm: Bool) async throws -> ManifestApplyResult {
        var parameters = type.requestParameters.objectValue ?? [:]
        let identity = document.identity
        parameters["namespace"] = .string(identity.namespace ?? "")
        parameters["name"] = .string(identity.name)
        parameters["expectedUID"] = .string(identity.uid)
        parameters["kind"] = .string(identity.kind)
        parameters["manifest"] = .string(source)
        parameters["confirm"] = .bool(confirm)
        return try decode((try await client.request("manifest.apply", parameters: .object(parameters))).result, as: ManifestApplyResult.self)
    }

    private func apply(event: CoreEnvelope) {
        if event.streamID == activeExecStreamID {
            if ["exec.stdout", "exec.stderr"].contains(event.type),
               let encoded = event.result?.objectValue?["dataBase64"]?.stringValue,
               let data = Data(base64Encoded: encoded) {
                terminalOutputSink?(data)
                return
            }
            if event.type == "exec.closed" || event.type == "exec.error" {
                activeExecStreamID = nil
                return
            }
        }
        if event.streamID == activeLogStreamID, event.type == "logs.data", let line = event.result?.objectValue?["line"]?.stringValue {
            logLines.append(line)
            if logLines.count > 10_000 { logLines.removeFirst(logLines.count - 10_000) }
            return
        }
        if event.streamID == activePortForwardStreamID, event.type == "portforward.closed" {
            activePortForward = nil
            activePortForwardStreamID = nil
            return
        }
        if event.streamID == activeStreamID, event.type == "resource.watch.closed" {
            activeStreamID = nil
            guard watchReconnectAttempts < 3 else {
                errorMessage = "K9k stopped reconnecting the resource watch after repeated failures. Use Refresh to retry."
                return
            }
            watchReconnectAttempts += 1
            let delay = UInt64(watchReconnectAttempts * watchReconnectAttempts) * 500_000_000
            Task { [weak self] in
                try? await Task.sleep(nanoseconds: delay)
                guard let self, self.activeStreamID == nil else { return }
                await self.loadResources()
            }
            return
        }
        guard event.streamID == activeStreamID, let result = event.result else { return }
        if event.type == "resource.deleted", let summary = try? decode(result, as: ResourceSummary.self) {
            resources.removeAll { $0.id == summary.id }
        } else if ["resource.added", "resource.modified"].contains(event.type), let summary = try? decode(result, as: ResourceSummary.self) {
            if let index = resources.firstIndex(where: { $0.id == summary.id }) { resources[index] = summary } else { resources.append(summary) }
        }
    }

    private func decode<T: Decodable>(_ value: JSONValue?, as type: T.Type) throws -> T {
        guard let value else { throw CoreError(code: "emptyResponse", message: "The helper returned no data.") }
        return try JSONDecoder.k9k.decode(T.self, from: JSONEncoder().encode(value))
    }
    private func decodeArray<T: Decodable>(_ value: JSONValue?, as type: T.Type) throws -> [T] { try decode(value, as: [T].self) }

}
