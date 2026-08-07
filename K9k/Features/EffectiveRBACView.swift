import SwiftUI

/// Explains direct Kubernetes RBAC declarations for a selected ServiceAccount,
/// User, or Group. It intentionally never calls SubjectAccessReview or makes
/// an impersonated authorization claim; the active-context access checker is
/// kept as a separate, authoritative operation.
struct EffectiveRBACView: View {
    @Environment(ClusterStore.self) private var store
    @Environment(\.dismiss) private var dismiss

    let initialResource: ResourceSummary?
    @State private var subjectKind: String
    @State private var subjectName: String
    @State private var subjectNamespace: String
    @State private var bindingNamespace: String
    @State private var analysis: EffectiveRBACAnalysis?
    @State private var isLoading = false

    init(initialResource: ResourceSummary?) {
        self.initialResource = initialResource
        let isServiceAccount = initialResource?.kind == "ServiceAccount"
        _subjectKind = State(initialValue: isServiceAccount ? "ServiceAccount" : "User")
        _subjectName = State(initialValue: isServiceAccount ? initialResource?.name ?? "" : "")
        _subjectNamespace = State(initialValue: isServiceAccount ? initialResource?.namespace ?? "" : "")
        _bindingNamespace = State(initialValue: "")
    }

    private var isServiceAccount: Bool { subjectKind == "ServiceAccount" }
    private var canInspect: Bool {
        !subjectName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
        (!isServiceAccount || !subjectNamespace.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty) &&
        (!isServiceAccount || bindingNamespace.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || bindingNamespace.trimmingCharacters(in: .whitespacesAndNewlines) == subjectNamespace.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Effective RBAC")
                        .font(.headline)
                    Text("Explain direct RoleBinding and ClusterRoleBinding grants without impersonating a subject.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("Close") { dismiss() }
            }
            .padding()
            Divider()

            Form {
                Section("Subject") {
                    Picker("Kind", selection: $subjectKind) {
                        Text("Service Account").tag("ServiceAccount")
                        Text("User").tag("User")
                        Text("Group").tag("Group")
                    }
                    TextField(isServiceAccount ? "Service account name" : "Subject name", text: $subjectName)
                    if isServiceAccount {
                        TextField("Namespace", text: $subjectNamespace)
                        if !bindingNamespace.isEmpty && bindingNamespace != subjectNamespace {
                            Label("A ServiceAccount’s RoleBindings are always read from its own namespace.", systemImage: "exclamationmark.triangle")
                                .font(.caption)
                                .foregroundStyle(.orange)
                        }
                    } else {
                        TextField("Limit RoleBindings to namespace (optional)", text: $bindingNamespace)
                        Text("Leave this blank to inspect matching RoleBindings across namespaces. The read is bounded and any limit is reported.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                Section("Interpretation") {
                    Label("This is a static RBAC declaration view, not an allow/deny decision.", systemImage: "info.circle")
                        .font(.caption)
                    Text("It does not resolve group membership, external authorizers, admission policy, or permissions inherited outside these visible RBAC objects. Use Check Access for the active kubeconfig identity.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                if let analysis {
                    analysisSections(analysis)
                } else if isLoading {
                    Section { ProgressView("Reading RBAC bindings…") }
                } else {
                    Section("Bindings") {
                        Text("Inspect a subject to view its direct RoleBinding and ClusterRoleBinding grants.")
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .formStyle(.grouped)
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            Divider()
            HStack {
                if let analysis {
                    Text("\(analysis.bindings.count) direct binding\(analysis.bindings.count == 1 ? "" : "s")")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    Text("Read-only Kubernetes API traversal.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("Inspect RBAC") { inspect() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!canInspect || isLoading)
            }
            .padding()
        }
        .frame(minWidth: 760, idealWidth: 880, minHeight: 560, idealHeight: 700)
        .onChange(of: subjectKind) { _, kind in
            analysis = nil
            if kind == "ServiceAccount" { bindingNamespace = "" }
        }
        .onChange(of: subjectName) { _, _ in analysis = nil }
        .onChange(of: subjectNamespace) { _, _ in analysis = nil }
        .onChange(of: bindingNamespace) { _, _ in analysis = nil }
    }

    @ViewBuilder private func analysisSections(_ analysis: EffectiveRBACAnalysis) -> some View {
        Section("Subject") {
            LabeledContent("Evaluated declaration", value: analysis.subject.displayName)
            if analysis.truncated {
                Label("Snapshot reached a safety limit", systemImage: "scope")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
        }

        Section("Direct bindings") {
            if analysis.bindings.isEmpty {
                ContentUnavailableView("No Direct Bindings Found", systemImage: "person.crop.circle.badge.questionmark", description: Text("No readable RoleBinding or ClusterRoleBinding directly names this subject in the inspected scope."))
            }
            ForEach(analysis.bindings) { binding in
                DisclosureGroup {
                    VStack(alignment: .leading, spacing: 10) {
                        LabeledContent("Role reference", value: binding.roleDisplayName)
                        if !binding.roleResolved {
                            Label(binding.warning ?? "The referenced role could not be read.", systemImage: "exclamationmark.triangle")
                                .font(.caption)
                                .foregroundStyle(.orange)
                        } else if binding.rules.isEmpty {
                            Text("The referenced role currently has no rules.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        } else {
                            ForEach(Array(binding.rules.enumerated()), id: \.offset) { _, rule in
                                ruleCard(rule)
                            }
                        }
                    }
                    .padding(.vertical, 6)
                } label: {
                    HStack(spacing: 10) {
                        Image(systemName: binding.kind == "ClusterRoleBinding" ? "globe" : "link")
                            .foregroundStyle(Color.accentColor)
                            .frame(width: 18)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(binding.title).fontWeight(.medium)
                            Text(binding.namespace ?? "Cluster-wide")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Text(binding.roleDisplayName)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
            }
        }

        if !analysis.warnings.isEmpty {
            Section(analysis.truncated ? "Bounded / Partial Snapshot" : "Limitations") {
                ForEach(analysis.warnings, id: \.self) { warning in
                    Label(warning, systemImage: "exclamationmark.triangle")
                        .font(.caption)
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private func ruleCard(_ rule: EffectiveRBACRule) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                ForEach(rule.verbs, id: \.self) { verb in
                    Text(verb)
                        .font(.caption.weight(.semibold))
                        .padding(.horizontal, 7)
                        .padding(.vertical, 3)
                        .background(.quaternary, in: Capsule())
                }
            }
            LabeledContent("API group", value: rule.groupDisplay).font(.caption)
            LabeledContent("Resources", value: rule.resourceDisplay).font(.caption)
            if !rule.resourceNames.isEmpty { LabeledContent("Resource names", value: rule.resourceNames.joined(separator: ", ")).font(.caption) }
            if !rule.nonResourceURLs.isEmpty { LabeledContent("Non-resource URLs", value: rule.nonResourceURLs.joined(separator: ", ")).font(.caption) }
        }
        .padding(10)
        .background(.quaternary, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
    }

    private func inspect() {
        guard canInspect else { return }
        isLoading = true
        analysis = nil
        Task {
            defer { isLoading = false }
            analysis = await store.inspectEffectiveRBAC(
                subjectKind: subjectKind,
                subjectName: subjectName,
                subjectNamespace: subjectNamespace,
                bindingNamespace: isServiceAccount ? "" : bindingNamespace
            )
        }
    }
}
