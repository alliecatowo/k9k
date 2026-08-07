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
    var selectedNamespace = "All Namespaces"
    var selectedResourceType: ResourceType?
    var resources: [ResourceSummary] = []
    var selectedResources = Set<ResourceSummary.ID>()
    var searchText = ""
    var labelSelector = ""
    var errorMessage: String?
    var isLoading = false
    var isReadOnly = false
    var activeStreamID: String?

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
            selectedResourceType = preferredResource(named: "pods") ?? discoveredResources.first
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
        do { discoveredResources = try decodeArray((try await client.request("discovery.list")).result, as: ResourceType.self) }
        catch { errorMessage = error.localizedDescription }
    }

    func loadNamespaces() async {
        do { namespaces = ["All Namespaces"] + (try decodeArray((try await client.request("namespace.list")).result, as: String.self)) }
        catch { errorMessage = error.localizedDescription }
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
            activeStreamID = streamID
            _ = try? await client.request("resource.watch", parameters: .object(params))
        } catch { errorMessage = error.localizedDescription }
    }

    func selectResourceType(_ type: ResourceType) async {
        selectedResourceType = type
        selectedResources.removeAll()
        await loadResources()
    }

    func deleteSelected() async {
        guard !isReadOnly, let type = selectedResourceType else { return }
        let selected = resources.filter { selectedResources.contains($0.id) }
        do {
            for resource in selected {
                _ = try await client.request("resource.delete", parameters: operationParameters(type: type, resource: resource, additional: ["confirm": .bool(true)]))
            }
            await loadResources()
        } catch { errorMessage = error.localizedDescription }
    }

    func copySelectedName() {
        guard let resource = resources.first(where: { selectedResources.contains($0.id) }) else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(resource.name, forType: .string)
    }

    func resource(for id: ResourceSummary.ID?) -> ResourceSummary? { guard let id else { return nil }; return resources.first(where: { $0.id == id }) }

    private func preferredResource(named name: String) -> ResourceType? { discoveredResources.first { $0.resource == name && $0.group.isEmpty } }
    private func operationParameters(type: ResourceType, resource: ResourceSummary, additional: [String: JSONValue] = [:]) -> JSONValue {
        var values = type.requestParameters.objectValue ?? [:]
        values["namespace"] = .string(resource.namespace ?? "")
        values["name"] = .string(resource.name)
        additional.forEach { values[$0.key] = $0.value }
        return .object(values)
    }

    private func apply(event: CoreEnvelope) {
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
