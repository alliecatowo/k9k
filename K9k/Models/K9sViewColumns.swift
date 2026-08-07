import Foundation

/// A native, bounded representation of one K9s `views.yaml` column. K9s
/// lets a view refer to renderer headers (for example `NAME`, `AGE`, or
/// `READY`) and to custom JSONPath expressions such as
/// `POD IP:.status.podIP|R`. The browser uses this value rather than treating
/// every configured view as one concatenated string column.
struct K9sViewColumn: Identifiable, Hashable {
    enum Source: Hashable {
        case name, namespace, status, age, kind, uid, resourceVersion, labels
        case label(String)
        case projection(String)
        case ready(readyPath: String, desiredPath: String)
    }

    let definition: String
    let title: String
    let source: Source
    let rightAligned: Bool
    let relativeTime: Bool

    var id: String { definition }

    /// Paths that must be included in the lean list/watch projection. Metadata
    /// is already part of every ResourceSummary and labels stay local, so only
    /// object fields that are not otherwise present cross the helper boundary.
    var projectionPaths: [String] {
        switch source {
        case .projection(let path): [path]
        case .ready(let ready, let desired): [ready, desired]
        default: []
        }
    }

    func value(for resource: ResourceSummary) -> String {
        switch source {
        case .name: resource.name
        case .namespace: resource.namespace?.isEmpty == false ? resource.namespace! : "—"
        case .status: resource.status
        case .age: resource.age
        case .kind: resource.kind
        case .uid: resource.uid
        case .resourceVersion: resource.resourceVersion ?? "—"
        case .labels:
            guard let labels = resource.labels, !labels.isEmpty else { return "—" }
            return labels.keys.sorted().map { "\($0)=\(labels[$0] ?? "")" }.joined(separator: ", ")
        case .label(let key):
            return resource.labels?[key] ?? "—"
        case .projection(let path):
            let rawValue = resource.columns?[path] ?? valueFromHydratedObject(path, resource.raw) ?? ""
            guard !rawValue.isEmpty else { return "—" }
            return relativeTime ? Self.relativeAge(rawValue) ?? rawValue : rawValue
        case .ready(let readyPath, let desiredPath):
            let ready = resource.columns?[readyPath] ?? valueFromHydratedObject(readyPath, resource.raw)
            let desired = resource.columns?[desiredPath] ?? valueFromHydratedObject(desiredPath, resource.raw)
            guard ready != nil || desired != nil else { return "—" }
            return "\(ready ?? "0")/\(desired ?? "0")"
        }
    }

    func matchesSortHeader(_ header: String) -> Bool {
        let expected = header.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        let configured = definition.split(separator: "|", maxSplits: 1).first.map(String.init) ?? definition
        let configuredHeader = configured.split(separator: ":", maxSplits: 1).first.map(String.init) ?? configured
        return title.uppercased() == expected || configuredHeader.trimmingCharacters(in: .whitespacesAndNewlines).uppercased() == expected
    }

    /// Tables start in the configured K9s order. Age is compared by the real
    /// creation date, not its already-humanised label; every other projected
    /// value gets a numeric comparison when possible and a localised string
    /// comparison otherwise.
    func compare(_ lhs: ResourceSummary, _ rhs: ResourceSummary) -> ComparisonResult {
        if case .age = source {
            return lhs.createdAt.compare(rhs.createdAt)
        }
        let left = value(for: lhs)
        let right = value(for: rhs)
        if let leftNumber = Double(left), let rightNumber = Double(right) {
            return leftNumber == rightNumber ? .orderedSame : (leftNumber < rightNumber ? .orderedAscending : .orderedDescending)
        }
        return left.localizedStandardCompare(right)
    }

    /// Parses the portable subset that K9k can project efficiently for every
    /// row. Invalid, array/filter, and unknown renderer expressions return nil
    /// instead of creating an empty decorative table column.
    static func parse(_ definition: String, for type: ResourceType) -> K9sViewColumn? {
        let original = definition.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !original.isEmpty else { return nil }

        let segments = original.split(separator: "|", omittingEmptySubsequences: false)
        let body = String(segments[0]).trimmingCharacters(in: .whitespacesAndNewlines)
        let flags = segments.dropFirst().joined().uppercased()
        // K9s `H` means hide unless the terminal is explicitly widened. A Mac
        // table has no equivalent terminal-width mode, so omit it completely.
        guard !flags.contains("H") else { return nil }

        let rightAligned = flags.contains("R") || flags.contains("N")
        let relativeTime = flags.contains("T")
        if let separator = body.firstIndex(of: ":") {
            let explicitTitle = String(body[..<separator]).trimmingCharacters(in: .whitespacesAndNewlines)
            let spec = String(body[body.index(after: separator)...]).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !explicitTitle.isEmpty, let source = source(forPathSpec: spec) else { return nil }
            return K9sViewColumn(definition: original, title: explicitTitle, source: source, rightAligned: rightAligned, relativeTime: relativeTime)
        }

        let symbol = body.uppercased()
        guard let source = source(forSymbol: symbol, type: type) else { return nil }
        return K9sViewColumn(definition: original, title: displayTitle(for: symbol), source: source, rightAligned: rightAligned, relativeTime: relativeTime)
    }

    private static func source(forSymbol symbol: String, type: ResourceType) -> Source? {
        switch symbol {
        case "NAME": .name
        case "NAMESPACE", "NS": .namespace
        case "STATUS", "PHASE": .status
        case "AGE", "CREATED": .age
        case "KIND": .kind
        case "UID": .uid
        case "RESOURCEVERSION", "RESOURCE VERSION", "RV": .resourceVersion
        case "LABELS": .labels
        case "IP", "POD IP":
            switch type.kind.lowercased() {
            case "pod": .projection("status.podIP")
            case "service": .projection("spec.clusterIP")
            default: nil
            }
        case "CLUSTER-IP", "CLUSTER IP":
            type.kind.lowercased() == "service" ? .projection("spec.clusterIP") : nil
        case "NODE":
            type.kind.lowercased() == "pod" ? .projection("spec.nodeName") : nil
        case "QOS", "QOS CLASS":
            type.kind.lowercased() == "pod" ? .projection("status.qosClass") : nil
        case "READY":
            switch type.kind.lowercased() {
            case "deployment", "statefulset", "replicaset", "replicationcontroller":
                .ready(readyPath: "status.readyReplicas", desiredPath: "spec.replicas")
            default: nil
            }
        case "REPLICAS", "DESIRED":
            ["deployment", "statefulset", "replicaset", "replicationcontroller"].contains(type.kind.lowercased()) ? .projection("spec.replicas") : nil
        case "AVAILABLE":
            type.kind.lowercased() == "deployment" ? .projection("status.availableReplicas") : nil
        case "UP-TO-DATE", "UP TO DATE":
            ["deployment", "statefulset", "daemonset"].contains(type.kind.lowercased()) ? .projection("status.updatedReplicas") : nil
        case "CURRENT":
            ["statefulset", "daemonset"].contains(type.kind.lowercased()) ? .projection("status.currentReplicas") : nil
        default: nil
        }
    }

    private static func source(forPathSpec spec: String) -> Source? {
        let trimmed = spec.trimmingCharacters(in: .whitespacesAndNewlines)
        let unwrapped: String
        if trimmed.first == "{", trimmed.last == "}" {
            unwrapped = String(trimmed.dropFirst().dropLast())
        } else {
            unwrapped = trimmed
        }
        guard unwrapped.first == "." else { return nil }
        let path = String(unwrapped.dropFirst())

        // Metadata fields are already included in ResourceSummary. Treat them
        // as native columns rather than asking every list/watch event to repeat
        // them in its projection map.
        switch path {
        case "metadata.name": return .name
        case "metadata.namespace": return .namespace
        case "metadata.uid": return .uid
        case "metadata.resourceVersion": return .resourceVersion
        case "metadata.creationTimestamp": return .age
        default: break
        }

        // `metadata.labels` is present in every lean summary. K9s JSONPath
        // escapes dotted label keys (`app\\.kubernetes\\.io/name`); resolve
        // those locally instead of making an impossible map traversal request
        // to the generic projection endpoint.
        if let labelKey = labelKey(from: path) { return .label(labelKey) }

        guard isSimpleProjectionPath(path) else { return nil }
        return .projection(path)
    }

    private static func isSimpleProjectionPath(_ path: String) -> Bool {
        let components = path.split(separator: ".", omittingEmptySubsequences: false)
        guard !components.isEmpty, components.count <= 12 else { return false }
        return components.allSatisfy { component in
            guard !component.isEmpty, component.count <= 128 else { return false }
            return component.allSatisfy { $0.isLetter || $0.isNumber || $0 == "_" || $0 == "-" || $0 == "/" }
        }
    }

    private static func labelKey(from path: String) -> String? {
        let prefix = "metadata.labels."
        guard path.hasPrefix(prefix) else { return nil }
        let escapedKey = String(path.dropFirst(prefix.count))
        guard !escapedKey.isEmpty,
              !escapedKey.contains("[") && !escapedKey.contains("]") && !escapedKey.contains("{") && !escapedKey.contains("}")
        else { return nil }
        var key = ""
        var escaping = false
        for scalar in escapedKey.unicodeScalars {
            if escaping {
                guard scalar == "." || scalar == "\\" else { return nil }
                key.unicodeScalars.append(scalar)
                escaping = false
            } else if scalar == "\\" {
                escaping = true
            } else if scalar.properties.isAlphabetic || scalar.properties.numericType != nil || scalar == "." || scalar == "-" || scalar == "_" || scalar == "/" {
                key.unicodeScalars.append(scalar)
            } else {
                return nil
            }
        }
        return escaping || key.isEmpty ? nil : key
    }

    private static func displayTitle(for symbol: String) -> String {
        switch symbol {
        case "NS": "Namespace"
        case "RV": "Resource Version"
        default: symbol.split(separator: " ").map { $0.prefix(1) + $0.dropFirst().lowercased() }.joined(separator: " ")
        }
    }

    private static func valueFromHydratedObject(_ path: String, _ raw: JSONValue?) -> String? {
        var current = raw
        for component in path.split(separator: ".") {
            current = current?.objectValue?[String(component)]
        }
        if let string = current?.stringValue { return string }
        if let number = current?.intValue { return String(number) }
        if let bool = current?.boolValue { return bool ? "true" : "false" }
        return nil
    }

    private static func relativeAge(_ string: String) -> String? {
        let formatter = ISO8601DateFormatter()
        guard let date = formatter.date(from: string) else { return nil }
        let seconds = max(0, Int(Date().timeIntervalSince(date)))
        switch seconds {
        case ..<60: return "\(seconds)s"
        case ..<3_600: return "\(seconds / 60)m"
        case ..<86_400: return "\(seconds / 3_600)h"
        default: return "\(seconds / 86_400)d"
        }
    }
}

extension K9sConfigSummary {
    /// K9s allows both a GVR-wide view and namespace-specific `gvr@regex`
    /// overrides. Prefer exact GVR keys and the most-specific matching
    /// namespace override, while still accepting a resource-name shorthand.
    func view(for type: ResourceType, namespace: String) -> K9sCustomView? {
        let gvr = type.gvr.lowercased()
        let resource = type.resource.lowercased()
        let selectedNamespace = namespace == "All Namespaces" ? "" : namespace
        return views.compactMap { view -> (K9sCustomView, Int)? in
            let parts = view.key.lowercased().split(separator: "@", maxSplits: 1, omittingEmptySubsequences: false)
            let key = String(parts[0]).trimmingCharacters(in: .whitespacesAndNewlines)
            let baseScore: Int
            switch key {
            case gvr: baseScore = 10_000
            case resource: baseScore = 1_000
            default: return nil
            }
            guard parts.count == 2 else { return (view, baseScore) }
            let pattern = String(parts[1])
            guard !selectedNamespace.isEmpty,
                  let expression = try? NSRegularExpression(pattern: pattern),
                  expression.firstMatch(in: selectedNamespace, range: NSRange(selectedNamespace.startIndex..., in: selectedNamespace)) != nil
            else { return nil }
            return (view, baseScore + 100 + pattern.count)
        }
        .max { $0.1 < $1.1 }?
        .0
    }
}
