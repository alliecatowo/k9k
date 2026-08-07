import SwiftUI

/// YAML is fetched in canonical, editable form by the helper. The editor never
/// invents a resource identity: every validation and apply pins the object's
/// original UID and lets Kubernetes admission perform the final validation.
struct ManifestEditorView: View {
    @Environment(ClusterStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    let resource: ResourceSummary
    let type: ResourceType
    @State private var document: ManifestDocument?
    @State private var source = ""
    @State private var isLoading = true
    @State private var isWorking = false
    @State private var validationMessage: String?
    @State private var applyConfirmation = false

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Edit Manifest").font(.headline)
                    Text("\(resource.kind) · \(resource.namespace ?? "cluster") / \(resource.name)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if let validationMessage {
                    Text(validationMessage).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                }
                Button("Close") { dismiss() }
            }
            .padding()
            Divider()

            if isLoading {
                ContentUnavailableView("Loading Manifest", systemImage: "doc.text", description: Text("Reading a canonical editable form from Kubernetes."))
            } else {
                TextEditor(text: $source)
                    .font(.system(.body, design: .monospaced))
                    .textEditorStyle(.plain)
                    .padding(12)
                    .background(.background)
                    .disabled(isWorking)
            }

            Divider()
            HStack(spacing: 10) {
                Text("K9k removes status and API-server metadata; it dry-runs before every apply.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Reload") { load() }.disabled(isLoading || isWorking)
                Button("Validate") { validate() }
                    .disabled(document == nil || isWorking)
                Button("Apply…") { applyConfirmation = true }
                    .keyboardShortcut(.defaultAction)
                    .disabled(document == nil || isWorking || store.isReadOnly || !store.canEditSelectedManifest)
            }
            .padding()
        }
        .frame(minWidth: 820, minHeight: 620)
        .task { load() }
        .confirmationDialog("Apply this manifest?", isPresented: $applyConfirmation, titleVisibility: .visible) {
            Button("Apply", role: .destructive) { apply() }
        } message: {
            Text("K9k will dry-run this exact YAML, then server-side apply it only if the selected object's UID still matches.")
        }
    }

    private func load() {
        isLoading = true
        validationMessage = nil
        Task {
            defer { isLoading = false }
            do {
                let loaded = try await store.fetchManifest(type: type, resource: resource)
                document = loaded
                source = loaded.yaml
            } catch {
                store.errorMessage = error.localizedDescription
            }
        }
    }

    private func validate() {
        guard let document else { return }
        isWorking = true
        validationMessage = nil
        Task {
            defer { isWorking = false }
            do {
                _ = try await store.validateManifest(type: type, document: document, source: source)
                validationMessage = "Validated by Kubernetes — no changes applied."
            } catch {
                validationMessage = "Validation failed."
                store.errorMessage = error.localizedDescription
            }
        }
    }

    private func apply() {
        guard let document else { return }
        isWorking = true
        validationMessage = nil
        Task {
            defer { isWorking = false }
            do {
                let result = try await store.applyManifest(type: type, document: document, source: source)
                self.document = result.manifest
                source = result.manifest.yaml
                validationMessage = "Applied by Kubernetes."
                await store.loadResources()
            } catch {
                validationMessage = "Apply failed."
                store.errorMessage = error.localizedDescription
            }
        }
    }
}
