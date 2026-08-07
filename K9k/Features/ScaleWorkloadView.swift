import SwiftUI

struct ScaleWorkloadView: View {
    @Environment(ClusterStore.self) private var store
    @Binding var isPresented: Bool
    @State private var replicas = ""
    @State private var isScaling = false

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Scale Workload")
                .font(.title2.weight(.semibold))
            if let resource = store.resource(for: store.selectedResources.first) {
                Text("\(resource.kind) · \(resource.name) · \(resource.namespace ?? "cluster scope")")
                    .foregroundStyle(.secondary)
            }
            Form {
                TextField("Replicas", text: $replicas)
                LabeledContent("Current", value: "\(store.selectedReplicaCount)")
                if let review = store.scaleAccess, !review.allowed {
                    LabeledContent("Permission", value: "Not allowed")
                    if let reason = review.reason, !reason.isEmpty {
                        Text(reason).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                    }
                }
            }
            .formStyle(.grouped)
            HStack {
                Button("Cancel") { isPresented = false }
                Spacer()
                Button("Scale") { scale() }
                    .buttonStyle(.glassProminent)
                    .disabled(isScaling || !store.canScaleSelected)
            }
        }
        .padding(24)
        .frame(width: 460)
        .onAppear {
            replicas = "\(store.selectedReplicaCount)"
            Task { await store.updateScaleAccess() }
        }
    }

    private func scale() {
        guard let desired = Int(replicas), desired >= 0 else {
            store.errorMessage = "Enter a whole-number replica count of zero or greater."
            return
        }
        isScaling = true
        Task {
            await store.scaleSelected(to: desired)
            isScaling = false
            if store.errorMessage == nil { isPresented = false }
        }
    }
}
