import AppKit
import SwiftUI

struct ResourceInspectorView: View {
    @Environment(ClusterStore.self) private var store
    let resource: ResourceSummary?
    let type: ResourceType?
    let events: [ClusterEvent]
    @State private var section: InspectorSection = .overview

    enum InspectorSection: String, CaseIterable, Identifiable { case overview = "Overview", events = "Events", raw = "Raw JSON", metadata = "Metadata"; var id: String { rawValue } }

    var body: some View {
        if let resource {
            VStack(spacing: 0) {
                Picker("Inspector section", selection: $section) { ForEach(InspectorSection.allCases) { Text($0.rawValue).tag($0) } }
                    .pickerStyle(.segmented)
                    .padding()
                Divider()
                ScrollView {
                    switch section {
                    case .overview: overview(resource)
                    case .events: eventList
                    case .raw: rawJSON(resource)
                    case .metadata: metadata(resource)
                    }
                }
            }
            .navigationTitle(resource.name)
        } else {
            ContentUnavailableView("No Selection", systemImage: "sidebar.right", description: Text("Select a \(type?.kind ?? "resource") to inspect its status, metadata, and raw Kubernetes object."))
        }
    }

    @ViewBuilder private var eventList: some View {
        if events.isEmpty {
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
            Section("Resource") {
                LabeledContent("Kind", value: resource.kind)
                LabeledContent("Name", value: resource.name)
                LabeledContent("Namespace", value: resource.namespace ?? "Cluster-scoped")
                LabeledContent("Status", value: resource.status)
                LabeledContent("Age", value: resource.age)
            }
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
            rbacDetails(resource)
            if resource.kind == "Pod", let containers = resource.raw?.objectValue?["spec"]?.objectValue?["containers"]?.arrayValue, !containers.isEmpty {
                Section("Containers") {
                    ForEach(Array(containers.enumerated()), id: \.offset) { _, container in
                        if let object = container.objectValue {
                            LabeledContent(object["name"]?.stringValue ?? "Container", value: object["image"]?.stringValue ?? "—")
                                .textSelection(.enabled)
                        }
                    }
                }
            }
            if let labels = resource.labels, !labels.isEmpty {
                Section("Labels") { ForEach(labels.sorted(by: { $0.key < $1.key }), id: \.key) { key, value in LabeledContent(key, value: value).textSelection(.enabled) } }
            }
        }
        .formStyle(.grouped)
        .padding(.bottom)
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
            }
        } else if store.isLoadingMetrics, resource.kind == "Pod" || resource.kind == "Node" {
            Section("Metrics") { LabeledContent("Usage") { ProgressView().controlSize(.small) } }
        } else if let message = store.metricsUnavailableMessage, resource.kind == "Pod" || resource.kind == "Node" {
            Section("Metrics") {
                LabeledContent("Usage", value: "Unavailable")
                Text(message).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
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

    @ViewBuilder private func metadata(_ resource: ResourceSummary) -> some View {
        Form {
            LabeledContent("UID", value: resource.uid).textSelection(.enabled)
            LabeledContent("API Version", value: resource.apiVersion)
            LabeledContent("Created", value: resource.createdAt.formatted(date: .abbreviated, time: .shortened))
        }
        .formStyle(.grouped)
    }

    @ViewBuilder private func rawJSON(_ resource: ResourceSummary) -> some View {
        VStack(spacing: 0) {
            HStack {
                Text("Sorted, API-faithful object JSON")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Copy JSON") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(prettyJSON(resource.raw), forType: .string)
                }
            }
            .padding(.horizontal)
            .padding(.vertical, 10)
            Divider()
            SyntaxHighlightedTextView(source: prettyJSON(resource.raw), language: .json)
        }
        .frame(minHeight: 300)
    }

    private func prettyJSON(_ raw: JSONValue?) -> String {
        guard let raw, let data = try? JSONEncoder().encode(raw), let value = try? JSONSerialization.jsonObject(with: data), let pretty = try? JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys]) else { return "No raw object available." }
        return String(decoding: pretty, as: UTF8.self)
    }

    private func list(_ value: JSONValue?, fallback: String = "") -> String {
        let values = value?.arrayValue?.compactMap(\.stringValue) ?? []
        return values.isEmpty ? fallback : values.joined(separator: ", ")
    }

    private func ruleSummary(_ rule: [String: JSONValue]) -> String {
        let verbs = list(rule["verbs"], fallback: "no verbs")
        if let urls = rule["nonResourceURLs"], !list(urls).isEmpty { return "\(verbs) · \(list(urls))" }
        return verbs
    }
}
