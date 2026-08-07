import SwiftUI

/// A native counterpart to `kubectl auth can-i`. It intentionally performs a
/// SelfSubjectAccessReview through the selected kubeconfig context rather than
/// trying to infer effective rights from Role and RoleBinding objects.
struct AccessCheckView: View {
    @Environment(ClusterStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    let initialType: ResourceType?
    let initialResource: ResourceSummary?
    @State private var typeID: String
    @State private var verb = "get"
    @State private var namespace: String
    @State private var name: String
    @State private var subresource = ""
    @State private var review: AccessReview?
    @State private var isChecking = false

    init(initialType: ResourceType?, initialResource: ResourceSummary?) {
        self.initialType = initialType
        self.initialResource = initialResource
        _typeID = State(initialValue: initialType?.id ?? "")
        _namespace = State(initialValue: initialResource?.namespace ?? "")
        _name = State(initialValue: initialResource?.name ?? "")
    }

    private var selectedType: ResourceType? {
        store.discoveredResources.first(where: { $0.id == typeID })
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Kubernetes Access Check").font(.headline)
                    Text("Uses the active context’s SelfSubjectAccessReview — equivalent to kubectl auth can-i.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("Close") { dismiss() }
            }
            .padding()
            Divider()

            Form {
                Picker("Resource", selection: $typeID) {
                    ForEach(store.discoveredResources.sorted { $0.kind.localizedStandardCompare($1.kind) == .orderedAscending }) { type in
                        Text(type.group.isEmpty ? type.kind : "\(type.kind) (\(type.group))").tag(type.id)
                    }
                }
                Picker("Verb", selection: $verb) {
                    ForEach(["get", "list", "watch", "create", "update", "patch", "delete", "deletecollection"], id: \.self) { Text($0).tag($0) }
                }
                if selectedType?.namespaced == true {
                    TextField("Namespace (optional)", text: $namespace)
                    TextField("Resource name (optional)", text: $name)
                } else {
                    TextField("Resource name (optional)", text: $name)
                }
                TextField("Subresource (optional)", text: $subresource)

                Section("Result") {
                    if let review {
                        Label(review.allowed ? "Allowed" : "Not allowed", systemImage: review.allowed ? "checkmark.shield.fill" : "xmark.shield.fill")
                            .foregroundStyle(review.allowed ? Color.green : Color.red)
                        if let reason = review.reason, !reason.isEmpty { Text(reason).font(.caption).foregroundStyle(.secondary) }
                        if let evaluationError = review.evaluationError, !evaluationError.isEmpty { Text(evaluationError).font(.caption).foregroundStyle(.red) }
                    } else {
                        Text("Run a check to ask the API server about this context’s active identity.")
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .formStyle(.grouped)
            .padding(.horizontal)

            Divider()
            HStack {
                Text("No resource is read or changed by this check.").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Check Access") { check() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(selectedType == nil || isChecking)
            }
            .padding()
        }
        .frame(minWidth: 680, minHeight: 510)
        .onChange(of: typeID) { _, _ in
            if selectedType?.namespaced != true { namespace = "" }
            review = nil
        }
    }

    private func check() {
        guard let selectedType else { return }
        isChecking = true
        review = nil
        Task {
            defer { isChecking = false }
            review = await store.checkAccess(
                verb: verb,
                type: selectedType,
                namespace: namespace,
                name: name,
                subresource: subresource
            )
        }
    }
}
