import SwiftUI

struct ResourceInspectorView: View {
    let resource: ResourceSummary?
    let type: ResourceType?
    @State private var section: InspectorSection = .overview

    enum InspectorSection: String, CaseIterable, Identifiable { case overview = "Overview", yaml = "YAML", metadata = "Metadata"; var id: String { rawValue } }

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
                    case .yaml: yaml(resource)
                    case .metadata: metadata(resource)
                    }
                }
            }
            .navigationTitle(resource.name)
        } else {
            ContentUnavailableView("No Selection", systemImage: "sidebar.right", description: Text("Select a \(type?.kind ?? "resource") to inspect its status, metadata, and raw Kubernetes object."))
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
            if let labels = resource.labels, !labels.isEmpty {
                Section("Labels") { ForEach(labels.sorted(by: { $0.key < $1.key }), id: \.key) { key, value in LabeledContent(key, value: value).textSelection(.enabled) } }
            }
        }
        .formStyle(.grouped)
        .padding(.bottom)
    }

    @ViewBuilder private func metadata(_ resource: ResourceSummary) -> some View {
        Form {
            LabeledContent("UID", value: resource.uid).textSelection(.enabled)
            LabeledContent("API Version", value: resource.apiVersion)
            LabeledContent("Created", value: resource.createdAt.formatted(date: .abbreviated, time: .shortened))
        }
        .formStyle(.grouped)
    }

    @ViewBuilder private func yaml(_ resource: ResourceSummary) -> some View {
        Text(prettyJSON(resource.raw))
            .font(.system(.caption, design: .monospaced))
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding()
    }

    private func prettyJSON(_ raw: JSONValue?) -> String {
        guard let raw, let data = try? JSONEncoder().encode(raw), let value = try? JSONSerialization.jsonObject(with: data), let pretty = try? JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys]) else { return "No raw object available." }
        return String(decoding: pretty, as: UTF8.self)
    }
}
