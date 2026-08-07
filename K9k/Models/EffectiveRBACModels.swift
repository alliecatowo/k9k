import Foundation

/// A bounded, declarative explanation of RBAC bindings which directly name a
/// subject. This is intentionally not presented as a `can-i` result: external
/// authorizers and group membership remain outside the Kubernetes RBAC graph.
struct EffectiveRBACAnalysis: Codable, Hashable {
    let subject: EffectiveRBACSubject
    let bindings: [EffectiveRBACBinding]
    let warnings: [String]
    let truncated: Bool
}

struct EffectiveRBACSubject: Codable, Hashable {
    let kind: String
    let name: String
    let namespace: String?

    var displayName: String {
        if kind == "ServiceAccount", let namespace, !namespace.isEmpty {
            return "ServiceAccount / \(namespace)/\(name)"
        }
        return "\(kind) / \(name)"
    }
}

struct EffectiveRBACBinding: Codable, Hashable, Identifiable {
    let kind: String
    let name: String
    let namespace: String?
    let roleKind: String
    let roleName: String
    let rules: [EffectiveRBACRule]
    let roleResolved: Bool
    let warning: String?

    var id: String { "\(kind)/\(namespace ?? "")/\(name)" }
    var title: String { "\(kind) / \(name)" }
    var roleDisplayName: String { "\(roleKind) / \(roleName)" }
}

struct EffectiveRBACRule: Codable, Hashable, Identifiable {
    let apiGroups: [String]
    let resources: [String]
    let verbs: [String]
    let resourceNames: [String]
    let nonResourceURLs: [String]

    var id: String {
        [verbs.joined(separator: ","), apiGroups.joined(separator: ","), resources.joined(separator: ","), resourceNames.joined(separator: ","), nonResourceURLs.joined(separator: ",")].joined(separator: "|")
    }
    var groupDisplay: String { apiGroups.isEmpty ? "core" : apiGroups.map { $0.isEmpty ? "core" : $0 }.joined(separator: ", ") }
    var resourceDisplay: String { resources.isEmpty ? "—" : resources.joined(separator: ", ") }
    var verbDisplay: String { verbs.isEmpty ? "—" : verbs.joined(separator: ", ") }
}
