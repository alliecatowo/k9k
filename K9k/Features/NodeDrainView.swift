import SwiftUI

/// A deliberately conservative native replacement for `k9s` drain. The
/// backend only uses the eviction API; this sheet makes the two material
/// choices visible before it asks Kubernetes to begin evicting Pods.
struct NodeDrainView: View {
    @Environment(ClusterStore.self) private var store
    let node: ResourceSummary
    @Binding var isPresented: Bool
    @State private var deleteEmptyDirData = false
    @State private var confirmationPresented = false

    private var isCordoned: Bool {
        node.raw?.objectValue?["spec"]?.objectValue?["unschedulable"]?.boolValue == true
    }

    var body: some View {
        @Bindable var store = store
        NavigationStack {
            Form {
                Section("Node") {
                    LabeledContent("Name", value: node.name)
                    LabeledContent("Scheduling", value: isCordoned ? "Cordoned" : "Schedulable")
                }
                Section("Drain safeguards") {
                    Text("K9k uses the Kubernetes eviction API. PodDisruptionBudgets and each Pod's termination grace period remain in force; K9k never force-deletes Pods.")
                        .font(.callout)
                    Text("DaemonSet and mirror Pods remain on the node. They are reported in the result, not silently removed.")
                        .font(.callout)
                    Toggle("Delete emptyDir data", isOn: $deleteEmptyDirData)
                    Text("Enable only if data held in emptyDir volumes may be discarded when their Pods are evicted.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if !isCordoned {
                    Section {
                        Label("Cordon this node before draining it.", systemImage: "exclamationmark.triangle")
                            .foregroundStyle(.orange)
                    }
                }
                if let result = store.nodeDrainResult, result.node == node.name {
                    drainResult(result)
                }
            }
            .formStyle(.grouped)
            .navigationTitle("Drain Node")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Close") { isPresented = false } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Drain Node…", role: .destructive) { confirmationPresented = true }
                        .disabled(!isCordoned || !store.canDrainSelectedNode)
                }
            }
        }
        .frame(minWidth: 540, minHeight: 470)
        .task { await store.updateNodeDrainAccess() }
        .confirmationDialog("Drain \(node.name)?", isPresented: $confirmationPresented, titleVisibility: .visible) {
            Button("Evict Eligible Pods", role: .destructive) {
                Task { await store.drainSelectedNode(deleteEmptyDirData: deleteEmptyDirData) }
            }
        } message: {
            Text("Eligible Pods will be evicted through Kubernetes. PodDisruptionBudgets can delay or reject individual evictions.")
        }
    }

    @ViewBuilder private func drainResult(_ result: NodeDrainResult) -> some View {
        Section("Drain result") {
            LabeledContent("Evictions accepted", value: "\(result.evicted.count)")
            LabeledContent("Skipped", value: "\(result.skipped.count)")
            LabeledContent("Blocked", value: "\(result.blocked.count)")
            LabeledContent("Failures", value: "\(result.failures.count)")
        }
        drainPods("Evicted", pods: result.evicted, tint: .green)
        drainPods("Skipped", pods: result.skipped, tint: .secondary)
        drainPods("Blocked", pods: result.blocked, tint: .orange)
        drainPods("Failures", pods: result.failures, tint: .red)
    }

    @ViewBuilder private func drainPods(_ title: String, pods: [NodeDrainPod], tint: Color) -> some View {
        if !pods.isEmpty {
            Section(title) {
                ForEach(pods) { pod in
                    VStack(alignment: .leading, spacing: 2) {
                        Text("\(pod.namespace)/\(pod.name)").fontWeight(.medium)
                        Text(pod.reason).font(.caption).foregroundStyle(tint).textSelection(.enabled)
                    }
                }
            }
        }
    }
}
