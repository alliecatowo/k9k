import Foundation
import Observation
import AppKit

private struct RollbackSource {
    let replicaSet: ResourceSummary
    let deploymentType: ResourceType
    let namespace: String
    let deployment: String
    let revision: String?
}

/// Retains the user's original target so a reconnect can resolve a Service's
/// current backing Pod again instead of blindly retrying a deleted Pod name.
private struct PortForwardReconnectRequest {
    let resource: ResourceSummary
    let remotePort: Int
    let localPort: Int
}

private struct PulseMetricsCollectionResult {
    let resource: String
    let items: [ResourceMetrics]
    let state: MetricsCollectionState
    let message: String?
    let sampledAt: Date

    var diagnostic: MetricsCollectionDiagnostic {
        MetricsCollectionDiagnostic(
            resource: resource, state: state, itemCount: items.count,
            message: message, sampledAt: sampledAt
        )
    }
}

@MainActor
@Observable
final class ClusterStore {
    var contexts: [KubeContext] = []
    var namespaces: [String] = ["All Namespaces"]
    var discoveredResources: [ResourceType] = []
    var selectedContext: KubeContext?
    var selectedNamespace = UserDefaults.standard.string(forKey: "k9k.selectedNamespace") ?? "All Namespaces" { didSet { UserDefaults.standard.set(selectedNamespace, forKey: "k9k.selectedNamespace") } }
    var favoriteNamespaces = UserDefaults.standard.stringArray(forKey: "k9k.favoriteNamespaces") ?? [] {
        didSet { UserDefaults.standard.set(favoriteNamespaces, forKey: "k9k.favoriteNamespaces") }
    }
    var selectedResourceType: ResourceType? {
        didSet {
            guard !isRestoringNavigation, oldValue != selectedResourceType, let selectedResourceType else { return }
            recordNavigation(to: selectedResourceType)
        }
    }
    var resources: [ResourceSummary] = []
    private(set) var visibleResources: [ResourceSummary] = []
    var loadedResourceCount = 0
    var remainingResourceCount: Int?
    var selectedResources = Set<ResourceSummary.ID>()
    var savedResourceQueries: [SavedResourceQuery] = []
    var searchText = "" {
        didSet { recomputeVisibleResources() }
    }
    var labelSelector = ""
    var fieldSelector = ""
    private var selectorResourceTypeID: String?
    var errorMessage: String?
    var isLoading = false
    var isReadOnly = UserDefaults.standard.bool(forKey: "k9k.readOnly") {
        didSet {
            UserDefaults.standard.set(isReadOnly, forKey: "k9k.readOnly")
            Task { await synchronizeReadOnlyPolicy() }
        }
    }
    var activeStreamID: String?
    var k9sAliases: [K9sAlias] = []
    var k9sConfig: K9sConfigSummary?
    var k9sConfigDocument: K9sConfigDocument?

    var events: [ClusterEvent] = []
    var logLines: [String] = []
    var activeLogStreamID: String?
    var activePortForwards: [ActivePortForward] = []
    var activeExecStreamID: String?
    var execAccess: AccessReview?
    var attachAccess: AccessReview?
    var debugAccess: AccessReview?
    var debugResult: PodDebugResult?
    var isCheckingExecAccess = false
    var manifestAccess: AccessReview?
    var isCheckingManifestAccess = false
    var resourceMetrics: ResourceMetrics?
    var metricsUnavailableMessage: String?
    var isLoadingMetrics = false
    var pulseNodeMetrics: [ResourceMetrics] = []
    var pulsePodMetrics: [ResourceMetrics] = []
    var pulseMetricsUnavailableMessage: String?
    var pulseMetricsDiagnostics: [MetricsCollectionDiagnostic] = []
    var isLoadingPulseMetrics = false
    var pulseDrilldownTarget: PulseDrilldownTarget?
    var deleteAccess: AccessReview?
    var isCheckingDeleteAccess = false
    var scaleAccess: AccessReview?
    var isCheckingScaleAccess = false
    var restartAccess: AccessReview?
    var isCheckingRestartAccess = false
    var rollbackAccess: AccessReview?
    var isCheckingRollbackAccess = false
    var cronJobTriggerAccess: AccessReview?
    var nodePatchAccess: AccessReview?
    var nodeDrainAccess: AccessReview?
    var nodeShellAccess: AccessReview?
    var nodeDrainResult: NodeDrainResult?
    var relationshipGraph: RelationshipGraph?
    var isLoadingRelationships = false
    private var deleteAccessGeneration = 0
    private var scaleAccessGeneration = 0
    private var restartAccessGeneration = 0
    private var rollbackAccessGeneration = 0
    private var execAccessGeneration = 0
    private var manifestAccessGeneration = 0
    private var eventsGeneration = 0
    private var resourceMetricsGeneration = 0
    // XRay may refresh while an operator also presses Refresh. Only the most
    // recent request is allowed to replace the visible topology; a slow older
    // snapshot must not rewind the sheet after a newer cluster read finishes.
    private var relationshipLoadGeneration = 0
    private var terminalOutputSink: ((Data) -> Void)?
    private var terminalColumns = 120
    private var terminalRows = 36
    private var watchReconnectAttempts = 0
    // Resource switches can overlap while a cluster is under load. Every list
    // and watch start carries this generation so a late Pod response can never
    // replace the table after the user has already selected Deployments.
    private var resourceLoadGeneration = 0
    private var resourceIndexByID: [ResourceSummary.ID: Int] = [:]
    private let resourcePageLimit = 250
    private var navigationHistory: [ResourceNavigationEntry] = []
    private var navigationHistoryIndex: Int?
    private var isRestoringNavigation = false
    private let navigationHistoryDefaultsKey = "k9k.resourceNavigationHistory.v1"
    private let navigationHistoryLimit = 30
    private let savedResourceQueriesDefaultsKey = "k9k.savedResourceQueries.v1"
    private let maximumPortForwardReconnectAttempts = 3
    private var portForwardReconnectRequests: [ActivePortForward.ID: PortForwardReconnectRequest] = [:]
    private var portForwardReconnectTasks: [ActivePortForward.ID: Task<Void, Never>] = [:]
    private var portForwardFailureMessages: [String: String] = [:]

    private let client = CoreClient()

    init() {
        client.onEvent = { [weak self] envelope in self?.apply(event: envelope) }
        loadNavigationHistory()
        loadSavedResourceQueries()
    }

    /// Current-context history only. This avoids a Back command unexpectedly
    /// switching credentials or cluster context while an operator is working.
    var recentResourceNavigation: [ResourceNavigationEntry] {
        navigationHistory
            .filter { $0.contextName == selectedContext?.name }
            .reversed()
    }

    var canNavigateBack: Bool {
        guard let navigationHistoryIndex else { return false }
        return navigationHistory[..<navigationHistoryIndex].contains { $0.contextName == selectedContext?.name }
    }

    var canNavigateForward: Bool {
        guard let navigationHistoryIndex else { return false }
        return navigationHistory.indices.dropFirst(navigationHistoryIndex + 1).contains { navigationHistory[$0].contextName == selectedContext?.name }
    }

    var hasUsablePulseMetrics: Bool {
        pulseMetricsDiagnostics.contains { $0.state == .available }
    }

    func openPulseDrilldown(for resource: ResourceSummary) {
        guard resource.kind == "Pod" || resource.kind == "Node" else { return }
        pulseDrilldownTarget = PulseDrilldownTarget(kind: resource.kind, namespace: resource.namespace, name: resource.name)
    }

    func clearPulseDrilldown() {
        pulseDrilldownTarget = nil
    }

    /// Cache search results when input changes instead of filtering the full
    /// live table on every SwiftUI body evaluation.
    private func recomputeVisibleResources() {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !query.isEmpty else {
            visibleResources = resources
            return
        }
        visibleResources = resources.filter { resource in
            resource.name.lowercased().contains(query) || resource.kind.lowercased().contains(query) || resource.namespace?.lowercased().contains(query) == true
        }
    }

    var orderedNamespaces: [String] {
        let favorites = favoriteNamespaces.filter { namespaces.contains($0) }
        let remaining = namespaces.filter { $0 != "All Namespaces" && !favorites.contains($0) }.sorted()
        return ["All Namespaces"] + favorites + remaining
    }

    func savedQueries(for type: ResourceType? = nil) -> [SavedResourceQuery] {
        guard let contextName = selectedContext?.name else { return [] }
        return savedResourceQueries
            .filter { $0.contextName == contextName && (type == nil || $0.resourceTypeID == type?.id) }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    func saveSelectorQuery(named name: String, labelSelector: String, fieldSelector: String) {
        guard let type = selectedResourceType, let contextName = selectedContext?.name else { return }
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty else {
            errorMessage = "Give the saved query a name."
            return
        }
        let query = SavedResourceQuery(
            id: UUID(), name: trimmedName, contextName: contextName, resourceTypeID: type.id,
            namespace: selectedNamespace, labelSelector: labelSelector, fieldSelector: fieldSelector, createdAt: Date()
        )
        savedResourceQueries.removeAll {
            $0.contextName == query.contextName && $0.resourceTypeID == query.resourceTypeID &&
                $0.name.caseInsensitiveCompare(query.name) == .orderedSame
        }
        savedResourceQueries.append(query)
        persistSavedResourceQueries()
    }

    func removeSavedSelectorQuery(_ query: SavedResourceQuery) {
        savedResourceQueries.removeAll { $0.id == query.id }
        persistSavedResourceQueries()
    }

    func applySavedSelectorQuery(_ query: SavedResourceQuery) async {
        guard query.contextName == selectedContext?.name,
              let type = discoveredResources.first(where: { $0.id == query.resourceTypeID }) else {
            errorMessage = "This saved query is unavailable in the active Kubernetes context."
            return
        }
        isRestoringNavigation = true
        selectedNamespace = query.namespace
        labelSelector = query.labelSelector
        fieldSelector = query.fieldSelector
        selectorResourceTypeID = type.id
        selectedResources.removeAll()
        selectedResourceType = type
        isRestoringNavigation = false
        recordNavigation(to: type)
        await loadResources()
    }

    func toggleFavoriteNamespace(_ namespace: String) {
        guard namespace != "All Namespaces" else { return }
        if let index = favoriteNamespaces.firstIndex(of: namespace) { favoriteNamespaces.remove(at: index) }
        else { favoriteNamespaces.append(namespace); favoriteNamespaces.sort() }
    }

    func connect() async {
        isLoading = true
        defer { isLoading = false }
        do {
            await synchronizeReadOnlyPolicy()
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

    /// UI disabling is useful feedback, but it is not a safety boundary. The
    /// helper owns the authoritative policy for its lifetime and rejects
    /// protected requests before they reach a Kubernetes client.
    private func synchronizeReadOnlyPolicy() async {
        do {
            _ = try await client.request("policy.readOnly", parameters: .object(["enabled": .bool(isReadOnly)]))
        } catch {
            errorMessage = "K9k could not synchronize read-only safety: \(error.localizedDescription)"
        }
    }

    func selectContext(_ context: KubeContext) async {
        isLoading = true
        defer { isLoading = false }
        do {
            // A loopback listener must never silently retarget a different
            // kubeconfig context. Stop its live SPDY stream and any scheduled
            // reconnect before swapping credentials/cluster clients.
            await closeAllPortForwards()
            _ = try await client.request("context.select", parameters: .object(["name": .string(context.name)]))
            selectedContext = context
            contexts = contexts.map { KubeContext(name: $0.name, cluster: $0.cluster, user: $0.user, namespace: $0.namespace, active: $0.id == context.id) }
            selectedNamespace = "All Namespaces"
            await loadNamespaces()
            await refreshDiscovery()
            await loadResources()
        } catch { errorMessage = error.localizedDescription }
    }

    /// Retrieves structural kubeconfig references only. The helper does not
    /// send the cluster server, certificate data, tokens, exec auth, or any
    /// other credential material over IPC.
    func inspectKubeconfigContext(_ context: KubeContext) async -> KubeconfigContextInspection? {
        do {
            return try decode((try await client.request("context.inspect", parameters: .object([
                "name": .string(context.name),
            ])).result), as: KubeconfigContextInspection.self)
        } catch {
            errorMessage = "Kubeconfig reference inspection failed: \(error.localizedDescription)"
            return nil
        }
    }

    func refreshDiscovery() async {
        do {
            discoveredResources = try decodeArray((try await client.request("discovery.list")).result, as: ResourceType.self)
            ensureDefaultResourceSelection()
        }
        catch { errorMessage = error.localizedDescription }
    }

    func updateActiveContextNamespace(_ namespace: String) async -> Bool {
        guard let context = selectedContext else { return false }
        do {
            _ = try await client.request("context.update", parameters: .object([
                "name": .string(context.name), "namespace": .string(namespace), "confirm": .bool(true)
            ]))
            contexts = contexts.map {
                KubeContext(name: $0.name, cluster: $0.cluster, user: $0.user, namespace: $0.id == context.id ? namespace : $0.namespace, active: $0.active)
            }
            selectedContext = contexts.first(where: { $0.id == context.id })
            return true
        } catch {
            errorMessage = error.localizedDescription
            return false
        }
    }

    func renameKubeContext(_ context: KubeContext, to newName: String) async -> Bool {
        let name = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, name != context.name else { return false }
        do {
            _ = try await client.request("context.rename", parameters: .object([
                "name": .string(context.name), "newName": .string(name), "confirm": .bool(true),
            ]))
            contexts = contexts.map {
                guard $0.id == context.id else { return $0 }
                return KubeContext(name: name, cluster: $0.cluster, user: $0.user, namespace: $0.namespace, active: $0.active)
            }
            selectedContext = contexts.first(where: { $0.active }) ?? selectedContext
            return true
        } catch {
            errorMessage = error.localizedDescription
            return false
        }
    }

    func copyKubeContext(_ context: KubeContext, to newName: String, namespace: String) async -> KubeContext? {
        let name = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, name != context.name else { return nil }
        do {
            _ = try await client.request("context.copy", parameters: .object([
                "source": .string(context.name), "newName": .string(name), "namespace": .string(namespace.trimmingCharacters(in: .whitespacesAndNewlines)), "confirm": .bool(true),
            ]))
            let copy = KubeContext(name: name, cluster: context.cluster, user: context.user, namespace: namespace.trimmingCharacters(in: .whitespacesAndNewlines), active: false)
            contexts.append(copy)
            contexts.sort { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
            return copy
        } catch {
            errorMessage = error.localizedDescription
            return nil
        }
    }

    func deleteKubeContext(_ context: KubeContext) async -> Bool {
        guard !context.active else {
            errorMessage = "Select a different context before deleting the active context."
            return false
        }
        do {
            _ = try await client.request("context.delete", parameters: .object([
                "name": .string(context.name), "confirm": .bool(true),
            ]))
            contexts.removeAll { $0.id == context.id }
            return true
        } catch {
            errorMessage = error.localizedDescription
            return false
        }
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
            // A reloaded view may require different lean projection paths.
            // Refresh the active collection so its new columns never render
            // against a stale list snapshot without their values.
            if selectedResourceType != nil { await loadResources() }
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
        resourceLoadGeneration &+= 1
        let generation = resourceLoadGeneration
        if selectorResourceTypeID != type.id {
            labelSelector = ""
            fieldSelector = ""
        }
        let previousStreamID = activeStreamID
        activeStreamID = nil
        if let previousStreamID { await client.cancel(streamID: previousStreamID) }
        isLoading = true
        defer {
            if generation == resourceLoadGeneration { isLoading = false }
        }
        do {
            let streamID = UUID().uuidString
            let namespace = selectedNamespace == "All Namespaces" ? "" : selectedNamespace
            var params = type.requestParameters.objectValue ?? [:]
            params["namespace"] = .string(namespace)
            params["selector"] = .string(labelSelector)
            params["fieldSelector"] = .string(fieldSelector)
            params["limit"] = .number(Double(resourcePageLimit))
            params["columns"] = .array(browserProjectionPaths(for: type).map(JSONValue.string))
            var continuation: String?
            var snapshot: [ResourceSummary] = []
            var snapshotResourceVersion = ""
            repeat {
                if let continuation, !continuation.isEmpty { params["continue"] = .string(continuation) }
                else { params.removeValue(forKey: "continue") }
                let page = try decode((try await client.request("resource.listPage", parameters: .object(params))).result, as: ResourceListPage.self)
                guard generation == resourceLoadGeneration, selectedResourceType?.id == type.id else { return }
                if snapshotResourceVersion.isEmpty { snapshotResourceVersion = page.resourceVersion }
                snapshot.append(contentsOf: page.items)
                installResources(snapshot)
                loadedResourceCount = snapshot.count
                remainingResourceCount = page.remainingItemCount
                continuation = page.continue
            } while continuation?.isEmpty == false
            guard generation == resourceLoadGeneration, selectedResourceType?.id == type.id else { return }
            applyK9sViewSort(for: type)
            watchReconnectAttempts = 0
            activeStreamID = streamID
            params.removeValue(forKey: "continue")
            params["streamID"] = .string(streamID)
            params["resourceVersion"] = .string(snapshotResourceVersion)
            params["compact"] = .bool(true)
            _ = try? await client.request("resource.watch", parameters: .object(params))
        } catch { errorMessage = error.localizedDescription }
    }

    /// Resolves the active K9s `views.yaml` definition once for both the
    /// browser layout and the lean backend projection. Keeping this in the
    /// store prevents the table from rendering columns that the list/watch
    /// request forgot to hydrate.
    func customColumns(for type: ResourceType) -> [K9sViewColumn] {
        guard let view = k9sConfig?.view(for: type, namespace: selectedNamespace) else { return [] }
        return view.columns.compactMap { K9sViewColumn.parse($0, for: type) }
    }

    /// A configured K9s view wins when it contains at least one usable
    /// column. Otherwise use the native operational layout for the resource
    /// type rather than emitting empty renderer placeholders.
    func browserColumns(for type: ResourceType) -> [K9sViewColumn] {
        let configured = customColumns(for: type)
        return configured.isEmpty ? K9sViewColumn.nativeColumns(for: type) : configured
    }

    private func browserProjectionPaths(for type: ResourceType) -> [String] {
        Array(Set(browserColumns(for: type).flatMap(\.projectionPaths))).sorted()
    }

    @discardableResult
    private func applyK9sViewSort(for type: ResourceType) -> Bool {
        guard let view = k9sConfig?.view(for: type, namespace: selectedNamespace) else { return false }
        let pieces = view.sortColumn.split(separator: ":", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        guard pieces.count == 2,
              let column = customColumns(for: type).first(where: { $0.matchesSortHeader(pieces[0]) })
        else { return false }
        let ascending = pieces[1].lowercased() == "asc"
        resources.sort {
            let result = column.compare($0, $1)
            return ascending ? result == .orderedAscending : result == .orderedDescending
        }
        resourceIndexByID = Dictionary(uniqueKeysWithValues: resources.enumerated().map { ($0.element.id, $0.offset) })
        recomputeVisibleResources()
        return true
    }

    private func installResources(_ values: [ResourceSummary]) {
        resources = values
        resourceIndexByID = Dictionary(uniqueKeysWithValues: values.enumerated().map { ($0.element.id, $0.offset) })
        recomputeVisibleResources()
    }

    func sortResources(using order: [KeyPathComparator<ResourceSummary>]) {
        resources.sort(using: order)
        resourceIndexByID = Dictionary(uniqueKeysWithValues: resources.enumerated().map { ($0.element.id, $0.offset) })
        recomputeVisibleResources()
    }

    func selectResourceType(_ type: ResourceType) async {
        guard selectedResourceType != type else { return }
        // A selector belongs to the GVR that created it. Clear it before the
        // assignment is recorded so history never labels a Deployment visit
        // with a stale Pod selector.
        if selectorResourceTypeID != type.id {
            labelSelector = ""
            fieldSelector = ""
            selectorResourceTypeID = nil
        }
        selectedResourceType = type
        selectedResources.removeAll()
        deleteAccess = nil
        scaleAccess = nil
        restartAccess = nil
        rollbackAccess = nil
        execAccess = nil
        manifestAccess = nil
        relationshipGraph = nil
    }

    func openHelmReleases() async {
        guard let secrets = preferredResource(named: "secrets") else { return }
        labelSelector = "owner=helm"
        fieldSelector = ""
        selectorResourceTypeID = secrets.id
        if selectedResourceType == secrets { recordNavigation(to: secrets) }
        else { await selectResourceType(secrets) }
        await loadResources()
    }

    /// Moves to a previously visited native resource list without changing the
    /// selected kubeconfig context. The root view observes the restored
    /// selection and reloads the matching list/watch exactly as a sidebar
    /// selection would.
    func navigateBack() async {
        guard let index = previousNavigationIndex() else { return }
        await restoreNavigation(at: index)
    }

    func navigateForward() async {
        guard let index = nextNavigationIndex() else { return }
        await restoreNavigation(at: index)
    }

    func openRecentNavigation(_ entry: ResourceNavigationEntry) async {
        guard let index = navigationHistory.firstIndex(of: entry) else { return }
        await restoreNavigation(at: index)
    }

    private func recordNavigation(to type: ResourceType) {
        let entry = ResourceNavigationEntry(
            resourceTypeID: type.id,
            kind: type.kind,
            resource: type.resource,
            namespace: selectedNamespace,
            labelSelector: labelSelector,
            fieldSelector: fieldSelector,
            contextName: selectedContext?.name,
            visitedAt: .now
        )

        if let index = navigationHistoryIndex,
           navigationHistory.indices.contains(index),
           navigationHistory[index].resourceTypeID == entry.resourceTypeID,
           navigationHistory[index].namespace == entry.namespace,
           navigationHistory[index].labelSelector == entry.labelSelector,
           navigationHistory[index].fieldSelector == entry.fieldSelector,
           navigationHistory[index].contextName == entry.contextName {
            return
        }

        if let index = navigationHistoryIndex {
            navigationHistory.removeSubrange((index + 1)..<navigationHistory.count)
        }
        navigationHistory.append(entry)
        if navigationHistory.count > navigationHistoryLimit {
            navigationHistory.removeFirst(navigationHistory.count - navigationHistoryLimit)
        }
        navigationHistoryIndex = navigationHistory.indices.last
        persistNavigationHistory()
    }

    private func previousNavigationIndex() -> Int? {
        guard let current = navigationHistoryIndex else { return nil }
        return navigationHistory[..<current].indices.reversed().first {
            navigationHistory[$0].contextName == selectedContext?.name
        }
    }

    private func nextNavigationIndex() -> Int? {
        guard let current = navigationHistoryIndex else { return nil }
        return navigationHistory.indices.dropFirst(current + 1).first {
            navigationHistory[$0].contextName == selectedContext?.name
        }
    }

    private func restoreNavigation(at index: Int) async {
        guard navigationHistory.indices.contains(index) else { return }
        let entry = navigationHistory[index]
        guard entry.contextName == selectedContext?.name else { return }
        guard let type = discoveredResources.first(where: { $0.id == entry.resourceTypeID }) else {
            errorMessage = "\(entry.kind) is no longer available in this cluster's API discovery."
            return
        }
        isRestoringNavigation = true
        selectedNamespace = namespaces.contains(entry.namespace) ? entry.namespace : "All Namespaces"
        labelSelector = entry.labelSelector
        fieldSelector = entry.fieldSelector
        selectorResourceTypeID = type.id
        selectedResources.removeAll()
        selectedResourceType = type
        isRestoringNavigation = false
        navigationHistoryIndex = index
    }

    private func loadNavigationHistory() {
        guard let data = UserDefaults.standard.data(forKey: navigationHistoryDefaultsKey),
              let saved = try? JSONDecoder().decode([ResourceNavigationEntry].self, from: data) else { return }
        navigationHistory = Array(saved.suffix(navigationHistoryLimit))
        navigationHistoryIndex = navigationHistory.indices.last
    }

    private func persistNavigationHistory() {
        guard let data = try? JSONEncoder().encode(navigationHistory) else { return }
        UserDefaults.standard.set(data, forKey: navigationHistoryDefaultsKey)
    }

    private func loadSavedResourceQueries() {
        guard let data = UserDefaults.standard.data(forKey: savedResourceQueriesDefaultsKey),
              let saved = try? JSONDecoder().decode([SavedResourceQuery].self, from: data) else { return }
        // Bound local state just as navigation history is bounded. This keeps
        // the app's preferences small even when a shared workstation has many
        // exploratory queries.
        savedResourceQueries = Array(saved.sorted { $0.createdAt > $1.createdAt }.prefix(100))
    }

    private func persistSavedResourceQueries() {
        guard let data = try? JSONEncoder().encode(savedResourceQueries) else { return }
        UserDefaults.standard.set(data, forKey: savedResourceQueriesDefaultsKey)
    }

    /// Keeps user-authored selectors associated with the current GVR. This
    /// prevents a Pod-specific field selector leaking into a later Node or CRD
    /// view, while allowing the user to refresh and keep the current filter.
    func pinSelectorsToCurrentResource() {
        selectorResourceTypeID = selectedResourceType?.id
        if let selectedResourceType { recordNavigation(to: selectedResourceType) }
    }

    func clearSelectors() {
        labelSelector = ""
        fieldSelector = ""
        selectorResourceTypeID = selectedResourceType?.id
        if let selectedResourceType { recordNavigation(to: selectedResourceType) }
    }

    func customJumps(for type: ResourceType) -> [K9sJump] {
        k9sConfig?.jumps.filter { $0.sourceGVR.lowercased() == type.gvr.lowercased() || $0.sourceGVR.lowercased() == type.resource.lowercased() } ?? []
    }

    func plugins(for type: ResourceType) -> [K9sPlugin] {
        let aliases = [type.resource, type.kind.lowercased(), type.gvr.lowercased()]
        return k9sConfig?.plugins.filter { plugin in
            plugin.scopes.contains("all") || plugin.scopes.contains(where: { aliases.contains($0.lowercased()) })
        } ?? []
    }

    func performCustomJump(_ jump: K9sJump, from resource: ResourceSummary, type: ResourceType) async {
        guard let target = resourceType(forGVR: jump.targetGVR) else {
            errorMessage = "K9k could not find the custom-jump target \(jump.targetGVR) in this cluster's discovery results."
            return
        }
        let namespace = resolvedJumpValue(jump.targetNamespace, resource: resource)
        if namespace.lowercased() == "all" { selectedNamespace = "All Namespaces" }
        else if !namespace.isEmpty, namespaces.contains(namespace) { selectedNamespace = namespace }
        else if jump.targetNamespace.isEmpty, let sourceNamespace = resource.namespace, namespaces.contains(sourceNamespace) { selectedNamespace = sourceNamespace }
        labelSelector = resolvedJumpValue(jump.labelSelector, resource: resource)
        fieldSelector = resolvedJumpValue(jump.fieldSelector, resource: resource)
        selectorResourceTypeID = target.id
        selectedResources.removeAll()
        selectedResourceType = target
        await loadResources()
    }

    func loadRelationships(for resource: ResourceSummary?, type: ResourceType?) async {
        guard let resource, let type else { relationshipGraph = nil; return }
        relationshipLoadGeneration += 1
        let generation = relationshipLoadGeneration
        isLoadingRelationships = true
        defer {
            if generation == relationshipLoadGeneration {
                isLoadingRelationships = false
            }
        }
        do {
            let graph = try decode(
                (try await client.request("relationships.get", parameters: operationParameters(type: type, resource: resource))).result,
                as: RelationshipGraph.self
            )
            guard generation == relationshipLoadGeneration else { return }
            relationshipGraph = graph
        } catch {
            guard generation == relationshipLoadGeneration else { return }
            relationshipGraph = nil
            errorMessage = error.localizedDescription
        }
    }

    /// Opens an object from the bounded Relationships/XRay snapshot in the
    /// normal resource browser.  Relationship nodes include an API version,
    /// rather than a guessed alias, so this keeps a Pod → ReplicaSet →
    /// Deployment investigation on the exact discovered GVR that Kubernetes
    /// advertised for the active cluster.
    ///
    /// The name field selector deliberately makes this a focused list rather
    /// than a one-off detail request: the destination still has the complete
    /// browser action surface, live watch, and normal Back/Forward history.
    @discardableResult
    func openRelationshipNode(_ node: RelationshipNode) async -> Bool {
        guard node.resolved else {
            errorMessage = "\(node.kind)/\(node.name) could not be resolved from this relationship snapshot."
            return false
        }
        guard let type = resourceType(apiVersion: node.apiVersion, kind: node.kind) else {
            errorMessage = "\(node.apiVersion) \(node.kind) is not available in this cluster's API discovery."
            return false
        }
        guard !type.namespaced || !(node.namespace ?? "").isEmpty else {
            errorMessage = "K9k cannot open \(node.kind)/\(node.name) because its namespace is unknown."
            return false
        }

        // Suppress the didSet history entry until all destination scope is in
        // place; otherwise Back could restore this GVR with the source
        // resource's selectors or namespace.
        isRestoringNavigation = true
        selectedNamespace = type.namespaced ? (node.namespace ?? "All Namespaces") : "All Namespaces"
        labelSelector = ""
        fieldSelector = "metadata.name=\(node.name)"
        selectorResourceTypeID = type.id
        selectedResources.removeAll()
        selectedResourceType = type
        isRestoringNavigation = false
        recordNavigation(to: type)

        // Match the normal browser lifecycle so any existing watch is
        // cancelled and the focused result starts its own watch. The list
        // generation gate makes a concurrent sidebar action win safely.
        await loadResources()
        guard selectedResourceType?.id == type.id else { return false }
        guard let target = resources.first(where: {
            $0.name == node.name && (!type.namespaced || $0.namespace == node.namespace)
        }) else {
            errorMessage = "\(node.kind)/\(node.name) is no longer available in \(type.namespaced ? (node.namespace ?? "this namespace") : "this cluster")."
            return false
        }
        selectedResources = [target.id]
        return true
    }

    /// Follows an object returned by a *confirmed* manifest import in the
    /// normal resource browser. Import identities originate in the helper's
    /// post-apply Kubernetes response, so this never guesses a plural from a
    /// Kind or reuses the importer's YAML as an authority for the destination.
    ///
    /// Like relationship navigation, the focused name selector deliberately
    /// keeps the regular list/watch lifecycle alive. In addition, the returned
    /// UID is checked after the list arrives: a delete-and-recreate at the same
    /// name cannot silently become the object an operator meant to follow.
    @discardableResult
    func openImportedManifest(_ document: ManifestDocument) async -> Bool {
        let identity = document.identity
        guard let contextName = selectedContext?.name else {
            errorMessage = "Connect to a Kubernetes context before following an imported object."
            return false
        }
        guard let type = discoveredResources.first(where: {
            $0.group == (identity.group ?? "") &&
                $0.version == identity.version &&
                $0.resource == identity.resource &&
                $0.namespaced == identity.namespaced &&
                $0.kind == identity.kind
        }) else {
            errorMessage = "K9k could not find the exact \(identity.group.map { "\($0)/" } ?? "")\(identity.version)/\(identity.resource) API resource in this context. Refresh discovery and try again."
            return false
        }

        let namespace: String
        if type.namespaced {
            guard let value = identity.namespace?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else {
                errorMessage = "K9k cannot follow \(identity.kind)/\(identity.name) because the import result has no namespace."
                return false
            }
            namespace = value
        } else {
            guard identity.namespace?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty != false else {
                errorMessage = "K9k cannot follow \(identity.kind)/\(identity.name) because a cluster-scoped import result contains a namespace."
                return false
            }
            namespace = "All Namespaces"
        }
        guard !identity.uid.isEmpty else {
            errorMessage = "K9k cannot follow \(identity.kind)/\(identity.name) because Kubernetes did not return an immutable UID."
            return false
        }

        // Install every part of the destination before recording it. This
        // produces one useful history entry rather than an intermediate GVR
        // with the source namespace or selector attached.
        isRestoringNavigation = true
        selectedNamespace = namespace
        labelSelector = ""
        fieldSelector = "metadata.name=\(identity.name)"
        selectorResourceTypeID = type.id
        selectedResources.removeAll()
        selectedResourceType = type
        isRestoringNavigation = false
        recordNavigation(to: type)

        await loadResources()
        guard selectedContext?.name == contextName,
              selectedResourceType?.id == type.id,
              selectedNamespace == namespace,
              fieldSelector == "metadata.name=\(identity.name)" else {
            // A newer navigation or context switch owns the browser now.
            return false
        }
        guard let target = resources.first(where: {
            $0.name == identity.name &&
                (!type.namespaced || $0.namespace == namespace) &&
                $0.uid == identity.uid
        }) else {
            errorMessage = "\(identity.kind)/\(identity.name) is no longer the object returned by the import. It may have been deleted or recreated."
            return false
        }
        selectedResources = [target.id]
        return true
    }

    /// Keeps selection changes lightweight enough for the system inspector's
    /// show/hide animation. Historically every row click started ten-plus
    /// independent access reviews and an event list request, even though the
    /// inspector initially renders only its overview. Action-specific sheets
    /// still review permission just before use; Events now starts its own
    /// polling only when that tab is visible.
    func loadSelectedResourceSummary(for selection: ResourceSummary.ID?) async {
        events = []
        resourceMetrics = nil
        metricsUnavailableMessage = nil
        isLoadingMetrics = false
        scaleAccess = nil
        restartAccess = nil
        rollbackAccess = nil
        cronJobTriggerAccess = nil
        nodePatchAccess = nil
        nodeDrainAccess = nil
        execAccess = nil
        attachAccess = nil
        debugAccess = nil
        manifestAccess = nil

        guard let initialResource = resource(for: selection) else {
            deleteAccess = nil
            isCheckingDeleteAccess = false
            return
        }

        let resource = await hydrateResourceIfNeeded(initialResource)
        guard selectedResources.contains(resource.id) else { return }

        // These are the only dynamic values present in the default Overview
        // tab. Run them concurrently so inspector presentation is never held
        // behind an unrelated action's authorization round trip.
        async let deleteReview: Void = updateDeleteAccess()
        async let metrics: Void = loadMetrics(for: resource)
        _ = await (deleteReview, metrics)
    }

    private func hydrateResourceIfNeeded(_ resource: ResourceSummary) async -> ResourceSummary {
        guard resource.raw == nil, let type = selectedResourceType else { return resource }
        do {
            let raw = try decode((try await client.request("resource.get", parameters: operationParameters(type: type, resource: resource))).result, as: JSONValue.self)
            guard let index = resourceIndexByID[resource.id], resources.indices.contains(index), resources[index].id == resource.id else { return resource }
            let hydrated = ResourceSummary(
                apiVersion: resource.apiVersion, kind: resource.kind, namespace: resource.namespace, name: resource.name, uid: resource.uid,
                resourceVersion: resource.resourceVersion, createdAt: resource.createdAt, age: resource.age, status: resource.status,
                labels: resource.labels, columns: resource.columns, raw: raw
            )
            resources[index] = hydrated
            return hydrated
        } catch {
            errorMessage = error.localizedDescription
            return resource
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

    /// K9s exposes rollback on an inactive ReplicaSet. The source revision must
    /// be owned by a Deployment and have no live replicas, so this cannot
    /// accidentally replace the active Deployment template with itself.
    var canRollbackSelected: Bool {
        !isReadOnly && selectedRollbackSource != nil && rollbackAccess?.allowed == true
    }

    var selectedRollbackDescription: String? {
        guard let source = selectedRollbackSource else { return nil }
        return "Deployment \(source.deployment) will receive the Pod template from inactive ReplicaSet \(source.replicaSet.name)\(source.revision.map { " (revision \($0))" } ?? "")."
    }

    var selectedCronJobResource: ResourceSummary? {
        guard selectedResourceType?.gvr == "batch/v1/cronjobs",
              selectedResources.count == 1,
              let resource = selectedSelectedResource,
              resource.namespace != nil else { return nil }
        return resource
    }

    var canTriggerSelectedCronJob: Bool {
        !isReadOnly && selectedCronJobResource != nil && cronJobTriggerAccess?.allowed == true
    }

    var selectedNodeResource: ResourceSummary? { guard selectedResources.count == 1, let resource = selectedSelectedResource, resource.kind == "Node" else { return nil }; return resource }
    var canPatchSelectedNode: Bool { !isReadOnly && selectedNodeResource != nil && nodePatchAccess?.allowed == true }
    var canDrainSelectedNode: Bool { !isReadOnly && selectedNodeResource != nil && nodeDrainAccess?.allowed == true }

    var canOpenExec: Bool {
        !isReadOnly && selectedPodResource != nil && execAccess?.allowed == true
    }

    var canOpenAttach: Bool {
        !isReadOnly && selectedPodResource != nil && attachAccess?.allowed == true
    }

    var canDebugSelectedPod: Bool { !isReadOnly && selectedPodResource != nil && debugAccess?.allowed == true }

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

    /// Performs a direct SelfSubjectAccessReview for the active kubeconfig
    /// identity. This is deliberately exposed as an explicit user tool instead
    /// of deriving permissions from RBAC objects, which can be incomplete when
    /// aggregated roles or external authorization are in play.
    func checkAccess(verb: String, type: ResourceType, namespace: String, name: String, subresource: String) async -> AccessReview? {
        var parameters = type.requestParameters.objectValue ?? [:]
        parameters["verb"] = .string(verb.trimmingCharacters(in: .whitespacesAndNewlines))
        let normalizedNamespace = namespace.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedSubresource = subresource.trimmingCharacters(in: .whitespacesAndNewlines)
        if type.namespaced { parameters["namespace"] = .string(normalizedNamespace) }
        if !normalizedName.isEmpty { parameters["name"] = .string(normalizedName) }
        if !normalizedSubresource.isEmpty { parameters["subresource"] = .string(normalizedSubresource) }
        do {
            return try decode((try await client.request("rbac.check", parameters: .object(parameters))).result, as: AccessReview.self)
        } catch {
            errorMessage = error.localizedDescription
            return nil
        }
    }

    /// Reads the declarative RBAC bindings which directly name an arbitrary
    /// subject. Unlike `checkAccess`, this never impersonates a subject and is
    /// deliberately labelled as a partial static explanation in the UI.
    func inspectEffectiveRBAC(subjectKind: String, subjectName: String, subjectNamespace: String, bindingNamespace: String) async -> EffectiveRBACAnalysis? {
        var parameters: [String: JSONValue] = [
            "subjectKind": .string(subjectKind.trimmingCharacters(in: .whitespacesAndNewlines)),
            "subjectName": .string(subjectName.trimmingCharacters(in: .whitespacesAndNewlines)),
        ]
        let normalizedSubjectNamespace = subjectNamespace.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedBindingNamespace = bindingNamespace.trimmingCharacters(in: .whitespacesAndNewlines)
        if !normalizedSubjectNamespace.isEmpty { parameters["subjectNamespace"] = .string(normalizedSubjectNamespace) }
        if !normalizedBindingNamespace.isEmpty { parameters["bindingNamespace"] = .string(normalizedBindingNamespace) }
        do {
            return try decode((try await client.request("rbac.effective", parameters: .object(parameters))).result, as: EffectiveRBACAnalysis.self)
        } catch {
            errorMessage = error.localizedDescription
            return nil
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

    func updateRollbackAccess() async {
        rollbackAccessGeneration &+= 1
        let generation = rollbackAccessGeneration
        guard let source = selectedRollbackSource else {
            rollbackAccess = nil
            isCheckingRollbackAccess = false
            return
        }
        isCheckingRollbackAccess = true
        defer {
            if generation == rollbackAccessGeneration { isCheckingRollbackAccess = false }
        }
        do {
            let review = try decode(
                (try await client.request("rbac.check", parameters: .object([
                    "verb": .string("patch"), "gvr": .string(source.deploymentType.gvr),
                    "namespace": .string(source.namespace), "name": .string(source.deployment),
                ]))).result,
                as: AccessReview.self
            )
            if generation == rollbackAccessGeneration { rollbackAccess = review }
        } catch {
            if generation == rollbackAccessGeneration {
                rollbackAccess = AccessReview(allowed: false, denied: false, reason: "K9k could not verify permission to roll back this Deployment: \(error.localizedDescription)", evaluationError: nil)
            }
        }
    }

    func rollbackSelected() async {
        guard !isReadOnly, let source = selectedRollbackSource else { return }
        await updateRollbackAccess()
        guard canRollbackSelected else {
            errorMessage = rollbackAccess?.reason ?? "The active Kubernetes identity is not authorized to roll back this Deployment."
            return
        }
        do {
            _ = try await client.request("deployment.rollback", parameters: .object([
                "namespace": .string(source.namespace),
                "replicaSet": .string(source.replicaSet.name),
                "expectedRSUID": .string(source.replicaSet.uid),
                "confirm": .bool(true),
            ]))
            await loadResources()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// Runs the existing Deployment/ReplicaSet rollback protocol for a
    /// revision first reviewed in Rollout History. The helper re-gets the
    /// ReplicaSet, verifies its UID/inactive state/controller, and replaces
    /// the template only after this fresh RBAC check and UI confirmation.
    func rollbackDeploymentRevision(_ revision: RolloutRevision, history: RolloutHistory) async -> Bool {
        guard !isReadOnly,
              history.workloadKind == "Deployment",
              revision.kind == "ReplicaSet",
              revision.rollbackEligible,
              !revision.uid.isEmpty,
              let deploymentType = resourceType(forGVR: "apps/v1/deployments")
        else { return false }
        do {
            let access = try decode(
                (try await client.request("rbac.check", parameters: .object([
                    "verb": .string("patch"), "gvr": .string(deploymentType.gvr),
                    "namespace": .string(history.namespace), "name": .string(history.workloadName),
                ]))).result,
                as: AccessReview.self
            )
            guard access.allowed else {
                errorMessage = access.reason ?? "The active Kubernetes identity is not authorized to roll back this Deployment."
                return false
            }
            _ = try await client.request("deployment.rollback", parameters: .object([
                "namespace": .string(history.namespace),
                "replicaSet": .string(revision.name),
                "expectedRSUID": .string(revision.uid),
                "confirm": .bool(true),
            ]))
            await loadResources()
            return true
        } catch {
            errorMessage = error.localizedDescription
            return false
        }
    }

    func updateCronJobTriggerAccess() async {
        guard let resource = selectedCronJobResource, let namespace = resource.namespace else {
            cronJobTriggerAccess = nil
            return
        }
        do {
            cronJobTriggerAccess = try decode(
                (try await client.request("rbac.check", parameters: .object([
                    "verb": .string("create"), "gvr": .string("batch/v1/jobs"),
                    "namespace": .string(namespace),
                ]))).result,
                as: AccessReview.self
            )
        } catch {
            cronJobTriggerAccess = AccessReview(allowed: false, denied: false, reason: "K9k could not verify permission to create a Job: \(error.localizedDescription)", evaluationError: nil)
        }
    }

    func triggerSelectedCronJob() async {
        guard !isReadOnly, let resource = selectedCronJobResource, let namespace = resource.namespace else { return }
        await updateCronJobTriggerAccess()
        guard canTriggerSelectedCronJob else {
            errorMessage = cronJobTriggerAccess?.reason ?? "The active Kubernetes identity is not authorized to create Jobs from this CronJob."
            return
        }
        do {
            _ = try await client.request("cronjob.trigger", parameters: .object([
                "namespace": .string(namespace), "cronJob": .string(resource.name), "confirm": .bool(true),
            ]))
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

    func updateNodeDrainAccess() async {
        guard selectedNodeResource != nil else { nodeDrainAccess = nil; return }
        do {
            nodeDrainAccess = try decode(
                (try await client.request("rbac.check", parameters: .object([
                    "group": .string("policy"), "version": .string("v1"), "resource": .string("pods"),
                    "subresource": .string("eviction"), "namespaced": .bool(true), "verb": .string("create")
                ]))).result,
                as: AccessReview.self
            )
        } catch {
            nodeDrainAccess = AccessReview(allowed: false, denied: false, reason: "K9k could not verify Pod eviction permission: \(error.localizedDescription)", evaluationError: nil)
        }
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

    func drainSelectedNode(deleteEmptyDirData: Bool) async {
        guard let node = selectedNodeResource, !isReadOnly else { return }
        await updateNodeDrainAccess()
        guard canDrainSelectedNode else {
            errorMessage = nodeDrainAccess?.reason ?? "The active Kubernetes identity is not authorized to evict Pods."
            return
        }
        do {
            nodeDrainResult = try decode(
                (try await client.request("node.drain", parameters: .object([
                    "node": .string(node.name), "ignoreDaemonSets": .bool(true),
                    "deleteEmptyDirData": .bool(deleteEmptyDirData), "confirm": .bool(true)
                ]))).result,
                as: NodeDrainResult.self
            )
            await loadResources()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// Resolve only an explicitly configured DaemonSet/container pair. The
    /// helper verifies the controller UID and actual node placement before it
    /// returns a target; K9k never fabricates a privileged node-debug Pod.
    func resolveNodeShell(node: String, namespace: String, daemonSet: String, container: String) async -> NodeShellTarget? {
        guard !isReadOnly else {
            errorMessage = "Disable read-only mode before opening a node shell."
            return nil
        }
        do {
            let target = try decode(
                (try await client.request("node.shell.resolve", parameters: .object([
                    "node": .string(node), "namespace": .string(namespace),
                    "daemonSet": .string(daemonSet), "container": .string(container)
                ]))).result,
                as: NodeShellTarget.self
            )
            await updateNodeShellAccess(for: target)
            guard nodeShellAccess?.allowed == true else {
                errorMessage = nodeShellAccess?.reason ?? "The active Kubernetes identity is not authorized to exec into the configured node shell Pod."
                return nil
            }
            return target
        } catch {
            errorMessage = error.localizedDescription
            return nil
        }
    }

    private func updateNodeShellAccess(for target: NodeShellTarget) async {
        do {
            nodeShellAccess = try decode(
                (try await client.request("rbac.check", parameters: .object([
                    "group": .string(""), "version": .string("v1"), "resource": .string("pods"),
                    "namespaced": .bool(true), "namespace": .string(target.namespace), "name": .string(target.pod),
                    "verb": .string("create"), "subresource": .string("exec")
                ]))).result,
                as: AccessReview.self
            )
        } catch {
            nodeShellAccess = AccessReview(allowed: false, denied: false, reason: "K9k could not verify node-shell exec permission: \(error.localizedDescription)", evaluationError: nil)
        }
    }

    func openNodeShell(target: NodeShellTarget, command: [String]) async {
        guard !isReadOnly, !command.isEmpty else { return }
        // Re-resolve immediately before exec. A DaemonSet rollout can replace
        // the originally displayed Pod while the terminal sheet is open; a
        // fresh controller/node/container verification avoids using that stale
        // target by name.
        guard let verifiedTarget = await resolveNodeShell(
            node: target.node, namespace: target.namespace,
            daemonSet: target.daemonSet, container: target.container
        ) else { return }
        await closeExec()
        let streamID = UUID().uuidString
        activeExecStreamID = streamID
        do {
            _ = try await client.request("exec.open", parameters: .object([
                "streamID": .string(streamID), "namespace": .string(verifiedTarget.namespace), "pod": .string(verifiedTarget.pod),
                "container": .string(verifiedTarget.container), "command": .array(command.map(JSONValue.string)),
                "tty": .bool(true), "stdin": .bool(true),
                "initialColumns": .number(Double(terminalColumns)), "initialRows": .number(Double(terminalRows))
            ]))
        } catch {
            activeExecStreamID = nil
            errorMessage = error.localizedDescription
        }
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

    /// File transfer uses the same direct pods/exec subresource as Terminal.
    /// Keep the access review at the Store boundary so a transfer sheet cannot
    /// accidentally turn a merely visible Pod into an executable target.
    func podExecAccess(for resource: ResourceSummary) async -> AccessReview {
        guard resource.kind == "Pod", let namespace = resource.namespace, !namespace.isEmpty else {
            return AccessReview(allowed: false, denied: false, reason: "File transfer requires a namespaced Pod.", evaluationError: nil)
        }
        do {
            return try decode(
                (try await client.request("rbac.check", parameters: .object([
                    "group": .string(""), "version": .string("v1"), "resource": .string("pods"),
                    "namespaced": .bool(true), "namespace": .string(namespace), "name": .string(resource.name),
                    "verb": .string("create"), "subresource": .string("exec")
                ]))).result,
                as: AccessReview.self
            )
        } catch {
            return AccessReview(allowed: false, denied: false, reason: "K9k could not verify Pod exec permission: \(error.localizedDescription)", evaluationError: nil)
        }
    }

    func updateAttachAccess() async {
        guard let type = selectedResourceType, let resource = selectedPodResource else { attachAccess = nil; return }
        do {
            attachAccess = try decode(
                (try await client.request("rbac.check", parameters: operationParameters(type: type, resource: resource, additional: [
                    "verb": .string("create"), "subresource": .string("attach")
                ]))).result,
                as: AccessReview.self
            )
        } catch {
            attachAccess = AccessReview(allowed: false, denied: false, reason: "K9k could not verify Pod attach permission: \(error.localizedDescription)", evaluationError: nil)
        }
    }

    func updateDebugAccess() async {
        guard let type = selectedResourceType, let resource = selectedPodResource else { debugAccess = nil; return }
        do {
            debugAccess = try decode(
                (try await client.request("rbac.check", parameters: operationParameters(type: type, resource: resource, additional: [
                    "verb": .string("update"), "subresource": .string("ephemeralcontainers")
                ]))).result,
                as: AccessReview.self
            )
        } catch {
            debugAccess = AccessReview(allowed: false, denied: false, reason: "K9k could not verify ephemeral-container permission: \(error.localizedDescription)", evaluationError: nil)
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

    func openAttach(for resource: ResourceSummary, container: String? = nil) async {
        guard resource.kind == "Pod", let namespace = resource.namespace else { return }
        await updateAttachAccess()
        guard canOpenAttach else {
            errorMessage = attachAccess?.reason ?? "The active Kubernetes identity is not authorized to attach to this Pod."
            return
        }
        await closeExec()
        let streamID = UUID().uuidString
        activeExecStreamID = streamID
        var parameters: [String: JSONValue] = [
            "streamID": .string(streamID), "namespace": .string(namespace), "pod": .string(resource.name),
            "tty": .bool(true), "stdin": .bool(true), "initialColumns": .number(Double(terminalColumns)), "initialRows": .number(Double(terminalRows))
        ]
        if let container, !container.isEmpty { parameters["container"] = .string(container) }
        do { _ = try await client.request("attach.open", parameters: .object(parameters)) }
        catch { activeExecStreamID = nil; errorMessage = error.localizedDescription }
    }

    func createDebugContainer(for resource: ResourceSummary, image: String, targetContainer: String) async {
        guard resource.kind == "Pod", let namespace = resource.namespace else { return }
        await updateDebugAccess()
        guard canDebugSelectedPod else { errorMessage = debugAccess?.reason ?? "The active Kubernetes identity is not authorized to add an ephemeral container."; return }
        do {
            debugResult = try decode(
                (try await client.request("pod.debug", parameters: .object([
                    "namespace": .string(namespace), "pod": .string(resource.name), "targetContainer": .string(targetContainer),
                    "image": .string(image), "confirm": .bool(true)
                ]))).result,
                as: PodDebugResult.self
            )
            await loadResources()
        } catch { errorMessage = error.localizedDescription }
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
        } catch { errorMessage = error.localizedDescription }
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

    /// Compares the current editor text to a fresh live read of the selected
    /// UID. The core performs a non-mutating SSA dry run, so defaulting and
    /// ownership conflicts are visible without a kubectl subprocess or write.
    func diffManifest(type: ResourceType, document: ManifestDocument, source: String) async throws -> ManifestDiffResult {
        var parameters = type.requestParameters.objectValue ?? [:]
        let identity = document.identity
        parameters["namespace"] = .string(identity.namespace ?? "")
        parameters["name"] = .string(identity.name)
        parameters["expectedUID"] = .string(identity.uid)
        parameters["kind"] = .string(identity.kind)
        parameters["manifest"] = .string(source)
        return try decode((try await client.request("manifest.diff", parameters: .object(parameters))).result, as: ManifestDiffResult.self)
    }

    /// Compares exactly one selected manifest-workspace document with the
    /// live object it declares. The helper resolves discovery and fresh UID on
    /// its own, preserving the editor's stale-object protection for local
    /// files that have never been opened in the resource browser.
    func diffImportedManifest(source: String) async throws -> ManifestDiffResult {
        try decode((try await client.request("manifest.diffImported", parameters: .object([
            "manifest": .string(source),
        ]))).result, as: ManifestDiffResult.self)
    }

    func applyManifest(type: ResourceType, document: ManifestDocument, source: String) async throws -> ManifestApplyResult {
        try await submitManifest(type: type, document: document, source: source, confirm: true)
    }

    func importManifestBatch(type: ResourceType, source: String, confirm: Bool) async throws -> ManifestBatchApplyResult {
        var parameters = type.requestParameters.objectValue ?? [:]
        parameters["manifest"] = .string(source)
        parameters["kind"] = .string(type.kind)
        parameters["confirm"] = .bool(confirm)
        return try decode((try await client.request("manifest.applyBatch", parameters: .object(parameters))).result, as: ManifestBatchApplyResult.self)
    }

    /// Imports a YAML stream that may contain different Kubernetes resource
    /// kinds. The helper resolves every document through the active cluster's
    /// discovery response before dry-running the entire stream, rather than
    /// trusting the UI to infer a GVR from a kind name.
    func importMixedManifests(source: String, confirm: Bool) async throws -> ManifestBatchApplyResult {
        let parameters: JSONValue = .object([
            "manifest": .string(source),
            "confirm": .bool(confirm),
        ])
        return try decode((try await client.request("manifest.applyMixed", parameters: parameters)).result, as: ManifestBatchApplyResult.self)
    }

    /// Preflights or deletes the immutable identities returned by a confirmed
    /// import. The helper rechecks RBAC and UID for the whole batch before any
    /// confirmed deletion starts; no local shell or kubectl process is used.
    func deleteImportedManifestBatch(_ items: [ManifestIdentity], confirm: Bool) async throws -> ManifestBatchDeleteResult {
        let identities: [JSONValue] = items.map { identity in
            .object([
                "group": .string(identity.group ?? ""),
                "version": .string(identity.version),
                "resource": .string(identity.resource),
                "namespaced": .bool(identity.namespaced),
                "namespace": .string(identity.namespace ?? ""),
                "name": .string(identity.name),
                "uid": .string(identity.uid),
                "kind": .string(identity.kind),
            ])
        }
        return try decode((try await client.request("manifest.deleteBatch", parameters: .object([
            "items": .array(identities), "confirm": .bool(confirm),
        ]))).result, as: ManifestBatchDeleteResult.self)
    }

    func copySelectedName() {
        guard let resource = resources.first(where: { selectedResources.contains($0.id) }) else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(resource.name, forType: .string)
    }

    func loadEvents(for resource: ResourceSummary?) async {
        eventsGeneration &+= 1
        let generation = eventsGeneration
        guard let resource, let namespace = resource.namespace, !namespace.isEmpty else {
            events = []
            return
        }
        do {
            let loaded = try decodeArray((try await client.request("resource.events", parameters: .object(["namespace": .string(namespace), "uid": .string(resource.uid)]))).result, as: ClusterEvent.self)
            if generation == eventsGeneration { events = loaded }
        } catch {
            if generation == eventsGeneration { events = [] }
        }
    }

    func loadMetrics(for resource: ResourceSummary?) async {
        resourceMetricsGeneration &+= 1
        let generation = resourceMetricsGeneration
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
        defer {
            if generation == resourceMetricsGeneration { isLoadingMetrics = false }
        }
        var parameters: [String: JSONValue] = [
            "resource": .string(metricResource),
            "name": .string(resource.name)
        ]
        if metricResource == "pods", let namespace = resource.namespace {
            parameters["namespace"] = .string(namespace)
        }
        do {
            let response = try decode((try await client.request("metrics.list", parameters: .object(parameters))).result, as: MetricsListResponse.self)
            if generation == resourceMetricsGeneration { resourceMetrics = response.items.first }
        } catch let error as CoreError where error.code == "metrics_unavailable" {
            if generation == resourceMetricsGeneration { metricsUnavailableMessage = error.message }
        } catch {
            if generation == resourceMetricsGeneration { metricsUnavailableMessage = "K9k could not load metrics: \(error.localizedDescription)" }
        }
    }

    /// Pulse samples the two cluster-wide metrics collections. It is kept
    /// independent from selection metrics so switching a resource never
    /// interrupts the operator's rolling cluster observation.
    func loadPulseMetrics() async {

        // Refresh and the five-second sampler can race. Keep exactly one pair
        // of collection requests in flight, rather than accumulating helper
        // requests while a slow Metrics Server catches up.
        guard !isLoadingPulseMetrics else { return }
        isLoadingPulseMetrics = true
        defer { isLoadingPulseMetrics = false }
        pulseMetricsUnavailableMessage = nil
        async let nodeResult = fetchPulseMetrics(resource: "nodes")
        async let podResult = fetchPulseMetrics(resource: "pods")
        let (nodes, pods) = await (nodeResult, podResult)
        guard !Task.isCancelled else { return }

        pulseNodeMetrics = nodes.items
        pulsePodMetrics = pods.items
        pulseMetricsDiagnostics = [nodes.diagnostic, pods.diagnostic]

        // A partial response still has value. Only use the unavailable empty
        // state when neither collection could provide data, and preserve the
        // individual diagnostics in every other case.
        guard !hasUsablePulseMetrics else { return }
        pulseMetricsUnavailableMessage = pulseMetricsDiagnostics
            .map { diagnostic in
                "\(diagnostic.title): \(diagnostic.message ?? diagnostic.state.displayName)"
            }
            .joined(separator: "\n")
    }

    private func fetchPulseMetrics(resource: String) async -> PulseMetricsCollectionResult {
        let sampledAt = Date.now
        do {
            let envelope = try await client.request("metrics.list", parameters: .object(["resource": .string(resource)]))
            let response = try decode(envelope.result, as: MetricsListResponse.self)
            return PulseMetricsCollectionResult(resource: resource, items: response.items, state: .available, message: nil, sampledAt: sampledAt)
        } catch let error as CoreError {
            let state: MetricsCollectionState = error.code == "metrics_unavailable" ? .unavailable : .failed
            return PulseMetricsCollectionResult(resource: resource, items: [], state: state, message: error.message, sampledAt: sampledAt)
        } catch is CancellationError {
            return PulseMetricsCollectionResult(resource: resource, items: [], state: .failed, message: "Sampling cancelled.", sampledAt: sampledAt)
        } catch {
            return PulseMetricsCollectionResult(resource: resource, items: [], state: .failed, message: "K9k could not load metrics: \(error.localizedDescription)", sampledAt: sampledAt)
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

    func openPortForward(for resource: ResourceSummary, remotePort: Int, localPort: Int = 0) async -> ActivePortForward? {
        guard resource.namespace != nil else { return nil }
        guard (1...65535).contains(remotePort), (0...65535).contains(localPort) else {
            errorMessage = "Ports must be between 1 and 65535 (or use 0 for an automatic local port)."
            return nil
        }
        do {
            guard resource.kind == "Service" || resource.kind == "Pod" else { return nil }
            let request = PortForwardReconnectRequest(resource: resource, remotePort: remotePort, localPort: localPort)
            let session = try await startPortForward(request)
            let forward = ActivePortForward(
                id: UUID(), streamID: session.streamID, binding: session.binding, connectionState: .connected
            )
            portForwardReconnectRequests[forward.id] = request
            activePortForwards.append(forward)
            return forward
        } catch {
            errorMessage = error.localizedDescription
            return nil
        }
    }

    private func startPortForward(_ request: PortForwardReconnectRequest) async throws -> (streamID: String, binding: PortForwardBinding) {
        guard let namespace = request.resource.namespace else {
            throw NSError(domain: "K9k", code: 5, userInfo: [NSLocalizedDescriptionKey: "The selected resource has no namespace for a port forward."])
        }
        let target: (pod: ResourceSummary, remotePort: Int)
        if request.resource.kind == "Service" {
            target = try await resolveServiceForward(request.resource, servicePort: request.remotePort)
        } else if request.resource.kind == "Pod" {
            target = (request.resource, request.remotePort)
        } else {
            throw NSError(domain: "K9k", code: 6, userInfo: [NSLocalizedDescriptionKey: "K9k can only port forward a Pod or Service."])
        }
        let streamID = UUID().uuidString
        let result = try await client.request("portforward.open", parameters: .object([
            "streamID": .string(streamID),
            "namespace": .string(namespace),
            "pod": .string(target.pod.name),
            "remotePort": .number(Double(target.remotePort)),
            "localPort": .number(Double(request.localPort)),
            "localAddress": .string("127.0.0.1")
        ]))
        return (streamID, try decode(result.result, as: PortForwardBinding.self))
    }

    /// Kubernetes port-forward itself only targets Pods. For a Service, match
    /// its selector against Pods locally through the helper and translate the
    /// chosen Service port to a numeric target port before opening that same
    /// direct SPDY tunnel. A selector-less or named-but-unresolvable Service is
    /// surfaced instead of guessing an endpoint.
    private func resolveServiceForward(_ service: ResourceSummary, servicePort: Int) async throws -> (pod: ResourceSummary, remotePort: Int) {
        guard let namespace = service.namespace,
              let spec = service.raw?.objectValue?["spec"]?.objectValue,
              let selectorObject = spec["selector"]?.objectValue,
              !selectorObject.isEmpty else {
            throw NSError(domain: "K9k", code: 1, userInfo: [NSLocalizedDescriptionKey: "This Service has no Pod selector, so K9k cannot choose a port-forward target."])
        }
        let selector = selectorObject.compactMap { key, value in value.stringValue.map { "\(key)=\($0)" } }.sorted().joined(separator: ",")
        let pods: [ResourceSummary] = try decodeArray(
            (try await client.request("resource.list", parameters: .object([
                "gvr": .string("v1/pods"), "namespaced": .bool(true), "namespace": .string(namespace), "selector": .string(selector),
            ]))).result,
            as: ResourceSummary.self
        )
        guard let pod = pods.sorted(by: { $0.name < $1.name }).first(where: { $0.status == "Running" }) ?? pods.sorted(by: { $0.name < $1.name }).first else {
            throw NSError(domain: "K9k", code: 2, userInfo: [NSLocalizedDescriptionKey: "No Pods match this Service selector in \(namespace)."])
        }
        let ports = spec["ports"]?.arrayValue ?? []
        guard let servicePortSpec = ports.first(where: { $0.objectValue?["port"]?.intValue == servicePort })?.objectValue else {
            throw NSError(domain: "K9k", code: 3, userInfo: [NSLocalizedDescriptionKey: "Port \(servicePort) is not exposed by Service \(service.name)."])
        }
        if let targetPort = servicePortSpec["targetPort"]?.intValue { return (pod, targetPort) }
        if let targetName = servicePortSpec["targetPort"]?.stringValue {
            let containers = pod.raw?.objectValue?["spec"]?.objectValue?["containers"]?.arrayValue ?? []
            for container in containers {
                if let port = container.objectValue?["ports"]?.arrayValue?.first(where: { $0.objectValue?["name"]?.stringValue == targetName })?.objectValue?["containerPort"]?.intValue {
                    return (pod, port)
                }
            }
            throw NSError(domain: "K9k", code: 4, userInfo: [NSLocalizedDescriptionKey: "Service target port \"\(targetName)\" is not declared by Pod \(pod.name)."])
        }
        return (pod, servicePort)
    }

    func closePortForward(streamID: String) async {
        guard let forward = activePortForwards.first(where: { $0.streamID == streamID }) else {
            await client.cancel(streamID: streamID)
            return
        }
        portForwardReconnectTasks.removeValue(forKey: forward.id)?.cancel()
        portForwardReconnectRequests.removeValue(forKey: forward.id)
        portForwardFailureMessages.removeValue(forKey: streamID)
        activePortForwards.removeAll { $0.id == forward.id }
        await client.cancel(streamID: streamID)
    }

    func retryPortForward(id: ActivePortForward.ID) {
        portForwardReconnectTasks.removeValue(forKey: id)?.cancel()
        guard let index = activePortForwards.firstIndex(where: { $0.id == id }) else { return }
        activePortForwards[index].connectionState = .reconnecting(attempt: 0, maximumAttempts: maximumPortForwardReconnectAttempts)
        schedulePortForwardReconnect(id: id)
    }

    private func closeAllPortForwards() async {
        let forwards = activePortForwards
        portForwardReconnectTasks.values.forEach { $0.cancel() }
        portForwardReconnectTasks.removeAll()
        portForwardReconnectRequests.removeAll()
        portForwardFailureMessages.removeAll()
        activePortForwards.removeAll()
        for forward in forwards { await client.cancel(streamID: forward.streamID) }
    }

    private func schedulePortForwardReconnect(id: ActivePortForward.ID, reason: String? = nil) {
        guard let index = activePortForwards.firstIndex(where: { $0.id == id }),
              portForwardReconnectRequests[id] != nil else { return }
        let nextAttempt: Int
        if case let .reconnecting(attempt, _) = activePortForwards[index].connectionState {
            nextAttempt = attempt + 1
        } else {
            nextAttempt = 1
        }
        guard nextAttempt <= maximumPortForwardReconnectAttempts else {
            activePortForwards[index].connectionState = .failed(message: reason ?? "K9k could not restore this tunnel. Retry when the target is available.")
            return
        }
        activePortForwards[index].connectionState = .reconnecting(attempt: nextAttempt, maximumAttempts: maximumPortForwardReconnectAttempts)
        let delay = UInt64(nextAttempt * nextAttempt) * 500_000_000
        portForwardReconnectTasks[id]?.cancel()
        portForwardReconnectTasks[id] = Task { [weak self] in
            do { try await Task.sleep(nanoseconds: delay) }
            catch { return }
            guard !Task.isCancelled else { return }
            await self?.reconnectPortForward(id: id)
        }
    }

    private func reconnectPortForward(id: ActivePortForward.ID) async {
        guard let request = portForwardReconnectRequests[id],
              activePortForwards.contains(where: { $0.id == id }) else { return }
        do {
            let session = try await startPortForward(request)
            guard let currentIndex = activePortForwards.firstIndex(where: { $0.id == id }) else {
                await client.cancel(streamID: session.streamID)
                return
            }
            activePortForwards[currentIndex].streamID = session.streamID
            activePortForwards[currentIndex].binding = session.binding
            activePortForwards[currentIndex].connectionState = .connected
            portForwardReconnectTasks.removeValue(forKey: id)
        } catch {
            guard let currentIndex = activePortForwards.firstIndex(where: { $0.id == id }) else { return }
            let message = error.localizedDescription
            if case let .reconnecting(attempt, _) = activePortForwards[currentIndex].connectionState,
               attempt >= maximumPortForwardReconnectAttempts {
                activePortForwards[currentIndex].connectionState = .failed(message: message)
                portForwardReconnectTasks.removeValue(forKey: id)
            } else {
                schedulePortForwardReconnect(id: id, reason: message)
            }
        }
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

    private var selectedRollbackSource: RollbackSource? {
        guard selectedResourceType?.gvr == "apps/v1/replicasets",
              selectedResources.count == 1,
              let resource = selectedSelectedResource,
              let namespace = resource.namespace,
              let raw = resource.raw?.objectValue,
              (raw["status"]?.objectValue?["replicas"]?.intValue ?? 0) == 0,
              raw["spec"]?.objectValue?["template"]?.objectValue != nil,
              let deploymentType = resourceType(forGVR: "apps/v1/deployments")
        else { return nil }
        let owners = raw["metadata"]?.objectValue?["ownerReferences"]?.arrayValue ?? []
        guard let owner = owners.first(where: { owner in
            let value = owner.objectValue
            return value?["controller"]?.boolValue == true &&
                value?["apiVersion"]?.stringValue == "apps/v1" &&
                value?["kind"]?.stringValue == "Deployment" &&
                !(value?["name"]?.stringValue ?? "").isEmpty
        })?.objectValue,
        let deployment = owner["name"]?.stringValue else { return nil }
        let revision = raw["metadata"]?.objectValue?["annotations"]?.objectValue?["deployment.kubernetes.io/revision"]?.stringValue
        return RollbackSource(replicaSet: resource, deploymentType: deploymentType, namespace: namespace, deployment: deployment, revision: revision)
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
    private func resourceType(forGVR value: String) -> ResourceType? {
        let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return discoveredResources.first { $0.gvr.lowercased() == normalized || $0.resource.lowercased() == normalized }
    }
    private func resourceType(apiVersion: String, kind: String) -> ResourceType? {
        let components = apiVersion.split(separator: "/", omittingEmptySubsequences: true)
        guard let version = components.last else { return nil }
        let group = components.dropLast().joined(separator: "/")
        return discoveredResources.first {
            $0.group.caseInsensitiveCompare(group) == .orderedSame &&
                $0.version.caseInsensitiveCompare(String(version)) == .orderedSame &&
                $0.kind.caseInsensitiveCompare(kind) == .orderedSame
        }
    }
    private func resolvedJumpValue(_ source: String, resource: ResourceSummary) -> String {
        var value = source
        let raw = resource.raw?.objectValue ?? [:]
        let metadata = raw["metadata"]?.objectValue ?? [:]
        value = value.replacingOccurrences(of: "{{.metadata.name}}", with: resource.name)
        value = value.replacingOccurrences(of: "{{.metadata.namespace}}", with: resource.namespace ?? "")
        for (key, item) in metadata["labels"]?.objectValue ?? [:] {
            value = value.replacingOccurrences(of: "{{.metadata.labels.\(key)}}", with: item.stringValue ?? "")
        }
        for (key, item) in metadata["annotations"]?.objectValue ?? [:] {
            value = value.replacingOccurrences(of: "{{.metadata.annotations.\(key)}}", with: item.stringValue ?? "")
        }
        return value
    }
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
        if event.type == "portforward.error", let streamID = event.streamID,
           let message = event.result?.objectValue?["message"]?.stringValue {
            portForwardFailureMessages[streamID] = message
            return
        }
        if event.type == "portforward.closed", let streamID = event.streamID {
            guard let forward = activePortForwards.first(where: { $0.streamID == streamID }) else { return }
            let failureMessage = portForwardFailureMessages.removeValue(forKey: streamID)
            let reason = event.result?.objectValue?["reason"]?.stringValue ?? "completed"
            guard reason != "cancelled" else {
                activePortForwards.removeAll { $0.id == forward.id }
                portForwardReconnectRequests.removeValue(forKey: forward.id)
                portForwardReconnectTasks.removeValue(forKey: forward.id)?.cancel()
                return
            }
            schedulePortForwardReconnect(id: forward.id, reason: failureMessage ?? "The port-forward connection closed unexpectedly.")
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
            if let index = resourceIndexByID[summary.id], resources.indices.contains(index) {
                resources.remove(at: index)
                resourceIndexByID.removeValue(forKey: summary.id)
                for offset in index..<resources.count { resourceIndexByID[resources[offset].id] = offset }
                recomputeVisibleResources()
            }
        } else if ["resource.added", "resource.modified"].contains(event.type), let summary = try? decode(result, as: ResourceSummary.self) {
            if let index = resourceIndexByID[summary.id], resources.indices.contains(index) {
                resources[index] = summary
            } else {
                resourceIndexByID[summary.id] = resources.count
                resources.append(summary)
            }
            if let type = selectedResourceType {
                if !applyK9sViewSort(for: type) { recomputeVisibleResources() }
            } else {
                recomputeVisibleResources()
            }
            if selectedResources.contains(summary.id) { Task { _ = await self.hydrateResourceIfNeeded(summary) } }
        }
    }

    private func decode<T: Decodable>(_ value: JSONValue?, as type: T.Type) throws -> T {
        guard let value else { throw CoreError(code: "emptyResponse", message: "The helper returned no data.") }
        return try JSONDecoder.k9k.decode(T.self, from: JSONEncoder().encode(value))
    }
    private func decodeArray<T: Decodable>(_ value: JSONValue?, as type: T.Type) throws -> [T] { try decode(value, as: [T].self) }

}
