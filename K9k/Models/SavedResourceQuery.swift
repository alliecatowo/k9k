import Foundation

/// A credential-free, local shortcut to a Kubernetes resource-list scope.
/// Queries never retain object contents or kubeconfig values; the active
/// cluster still validates selectors when the query is opened.
struct SavedResourceQuery: Codable, Identifiable, Hashable {
    let id: UUID
    let name: String
    let contextName: String
    let resourceTypeID: String
    let namespace: String
    let labelSelector: String
    let fieldSelector: String
    let createdAt: Date

    var detail: String {
        var values = [namespace == "All Namespaces" ? "All namespaces" : namespace]
        if !labelSelector.isEmpty { values.append("label: \(labelSelector)") }
        if !fieldSelector.isEmpty { values.append("field: \(fieldSelector)") }
        return values.joined(separator: " · ")
    }
}
