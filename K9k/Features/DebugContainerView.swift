import SwiftUI

struct DebugContainerView: View {
    @Environment(ClusterStore.self) private var store
    let resource: ResourceSummary
    @Binding var isPresented: Bool
    @State private var image = "busybox:1.36"
    @State private var target = ""
    @State private var confirmationPresented = false

    private var containers: [String] {
        resource.raw?.objectValue?["spec"]?.objectValue?["containers"]?.arrayValue?.compactMap { $0.objectValue?["name"]?.stringValue } ?? []
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Target") {
                    LabeledContent("Pod", value: "\(resource.namespace ?? "default") / \(resource.name)")
                    Picker("Target container", selection: $target) { ForEach(containers, id: \.self) { Text($0).tag($0) } }
                    Text("The debug container shares the target container's process namespace when the cluster supports it.").font(.caption).foregroundStyle(.secondary)
                }
                Section("Debug image") {
                    TextField("Image", text: $image)
                    Text("K9k starts `/bin/sh` in a new ephemeral container. Admission, image policy, and Pod security restrictions still apply.").font(.caption).foregroundStyle(.secondary)
                }
                if let result = store.debugResult, result.pod == resource.name, result.namespace == resource.namespace {
                    Section("Created") {
                        LabeledContent("Container", value: result.container)
                        Text("Refresh the Pod, then select the new container in Pod Terminal to connect.").font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            .formStyle(.grouped)
            .navigationTitle("Debug Container")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Close") { isPresented = false } }
                ToolbarItem(placement: .confirmationAction) { Button("Create…", role: .destructive) { confirmationPresented = true }.disabled(image.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || target.isEmpty) }
            }
        }
        .frame(minWidth: 520, minHeight: 350)
        .onAppear { target = containers.first ?? "" }
        .confirmationDialog("Create debug container?", isPresented: $confirmationPresented, titleVisibility: .visible) {
            Button("Create Ephemeral Container", role: .destructive) { Task { await store.createDebugContainer(for: resource, image: image.trimmingCharacters(in: .whitespacesAndNewlines), targetContainer: target) } }
        } message: { Text("This adds an ephemeral container to the live Pod. It cannot be removed without replacing the Pod.") }
    }
}
