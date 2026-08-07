import SwiftUI

/// A bounded native rollout history. It is intentionally metadata-only: the
/// helper never transfers historical PodTemplates, and the only mutation path
/// reuses the existing UID-checked inactive ReplicaSet rollback operation.
struct RolloutHistorySection: View {
    let resource: ResourceSummary
    let type: ResourceType

    @State private var client = CoreClient()
    @State private var history: RolloutHistory?
    @State private var isLoading = false
    @State private var errorMessage: String?
    @State private var selectedRevision: RolloutRevision?

    var body: some View {
        Section("Revision History") {
            if isLoading && history == nil {
                LabeledContent("Revisions") { ProgressView().controlSize(.small) }
            } else if let history {
                if history.revisions.isEmpty {
                    Text("No Kubernetes-owned revision objects were found.")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(history.revisions) { revision in
                        Button { selectedRevision = revision } label: {
                            HStack(alignment: .firstTextBaseline, spacing: 9) {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(revision.revision?.isEmpty == false ? "Revision \(revision.revision!)" : revision.name)
                                        .fontWeight(.medium)
                                    Text(revision.name)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                        .lineLimit(1)
                                }
                                Spacer(minLength: 8)
                                Text(revision.status)
                                    .font(.caption)
                                    .foregroundStyle(statusColor(revision.status))
                                Image(systemName: "chevron.right")
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(.tertiary)
                            }
                        }
                        .buttonStyle(.plain)
                        .accessibilityElement(children: .combine)
                        .accessibilityLabel("\(history.workloadKind) revision \(revision.revision ?? revision.name), \(revision.status)")
                        .accessibilityHint("Opens revision metadata and guarded rollback availability")
                    }
                }
                if history.truncated {
                    Text("Showing the newest \(history.revisions.count) matching revisions; additional history was not read.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Text(history.workloadKind == "Deployment" ? "Only inactive ReplicaSets may offer a guarded rollback after an access review." : "Kubernetes exposes these controller revisions for review; K9k does not infer a template rollback for this workload kind.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else if let errorMessage {
                LabeledContent("History", value: "Unavailable")
                Text(errorMessage).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
            }
        }
        .task(id: "\(resource.id)|\(resource.resourceVersion ?? \"")") { await load() }
        .onDisappear { client.stop() }
        .sheet(item: $selectedRevision) { revision in
            if let history {
                RolloutRevisionInspectionView(history: history, revision: revision)
            }
        }
    }

    private func load() async {
        guard resource.namespace?.isEmpty == false else { return }
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }
        do {
            try await requireReadAccess()
            let envelope = try await client.request("rollout.history", parameters: .object([
                "group": .string(type.group), "version": .string(type.version), "resource": .string(type.resource),
                "namespace": .string(resource.namespace!), "name": .string(resource.name), "expectedUID": .string(resource.uid),
            ]))
            guard let result = envelope.result else { throw CoreError(code: "emptyResponse", message: "The helper returned no rollout history.") }
            history = try JSONDecoder.k9k.decode(RolloutHistory.self, from: JSONEncoder().encode(result))
        } catch {
            history = nil
            errorMessage = "K9k could not load rollout history: \(error.localizedDescription)"
        }
    }

    private func requireReadAccess() async throws {
        let historyResource = type.resource == "deployments" || type.resource == "replicasets" ? "replicasets" : "controllerrevisions"
        let checks: [(verb: String, gvr: String, name: String)] = [
            ("get", type.gvr, resource.name),
            ("list", "apps/v1/\(historyResource)", ""),
        ]
        for check in checks {
            let envelope = try await client.request("rbac.check", parameters: .object([
                "verb": .string(check.verb), "gvr": .string(check.gvr), "namespace": .string(resource.namespace ?? ""), "name": .string(check.name),
            ]))
            guard let result = envelope.result else { throw CoreError(code: "emptyResponse", message: "The helper returned no access review.") }
            let access = try JSONDecoder.k9k.decode(AccessReview.self, from: JSONEncoder().encode(result))
            guard access.allowed else { throw CoreError(code: "forbidden", message: access.reason ?? "The active Kubernetes identity cannot \(check.verb) \(check.gvr).") }
        }
    }

    private func statusColor(_ status: String) -> Color {
        switch status.lowercased() {
        case "current", "active": .green
        case "updating": .orange
        default: .secondary
        }
    }
}

private struct RolloutRevisionInspectionView: View {
    @Environment(ClusterStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    let history: RolloutHistory
    let revision: RolloutRevision
    @State private var confirmationPresented = false
    @State private var isRollingBack = false

    private var canRollback: Bool {
        !store.isReadOnly && history.workloadKind == "Deployment" && revision.kind == "ReplicaSet" && revision.rollbackEligible
    }

    var body: some View {
        Form {
            Section("Revision") {
                LabeledContent("Workload", value: "\(history.workloadKind) \(history.workloadName)")
                LabeledContent("Revision", value: revision.revision?.isEmpty == false ? revision.revision! : "Not annotated")
                LabeledContent("Source", value: "\(revision.kind) \(revision.name)")
                LabeledContent("Status", value: revision.status)
                LabeledContent("Created", value: revision.createdAt.formatted(date: .abbreviated, time: .shortened))
                LabeledContent("Age", value: revision.age)
                LabeledContent("UID", value: revision.uid).textSelection(.enabled)
            }
            Section("Safety") {
                if canRollback {
                    Label("This inactive ReplicaSet can be reviewed for rollback.", systemImage: "checkmark.shield")
                        .foregroundStyle(.green)
                    Text("K9k will re-check Deployment patch permission and the ReplicaSet UID, owner, and inactive status immediately before replacing the Deployment template.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    Text(history.workloadKind == "Deployment" ? "Only inactive Deployment-owned ReplicaSets are rollback candidates." : "This Kubernetes workload history is read-only; K9k does not infer a template rollback for this resource kind.")
                        .foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
        .frame(minWidth: 460, minHeight: 330)
        .navigationTitle(revision.revision?.isEmpty == false ? "Revision \(revision.revision!)" : revision.name)
        .toolbar {
            if canRollback {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Roll Back…", systemImage: "arrow.uturn.backward") { confirmationPresented = true }
                        .disabled(isRollingBack)
                }
            }
        }
        .confirmationDialog("Roll Back \(history.workloadName) to This Revision?", isPresented: $confirmationPresented, titleVisibility: .visible) {
            Button("Roll Back", role: .destructive) {
                Task {
                    isRollingBack = true
                    defer { isRollingBack = false }
                    if await store.rollbackDeploymentRevision(revision, history: history) { dismiss() }
                }
            }
        } message: {
            Text("K9k will replace the current Deployment Pod template with the template from inactive ReplicaSet \(revision.name). This triggers a new rollout.")
        }
    }
}
