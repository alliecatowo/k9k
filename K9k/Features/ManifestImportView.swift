import AppKit
import SwiftUI

struct ManifestImportView: View {
    @Environment(ClusterStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    let type: ResourceType
    @State private var source = ""
    @State private var isWorking = false
    @State private var validationMessage: String?
    @State private var applyConfirmation = false

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Import \(type.kind) Manifest").font(.headline)
                    Text("K9k validates against the selected cluster before it creates anything.").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button("Open YAML…") { openFile() }.disabled(isWorking)
                Button("Close") { dismiss() }
            }.padding()
            Divider()
            TextEditor(text: $source).font(.system(.body, design: .monospaced)).padding(10).disabled(isWorking)
            Divider()
            HStack {
                Text(validationMessage ?? "Paste YAML or open a YAML file. Namespace and name come from the manifest.")
                    .font(.caption).foregroundStyle(.secondary).lineLimit(2)
                Spacer()
                Button("Validate") { validate() }.disabled(source.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isWorking)
                Button("Create…") { applyConfirmation = true }.disabled(source.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isWorking || store.isReadOnly)
            }.padding()
        }
        .frame(minWidth: 820, minHeight: 620)
        .confirmationDialog("Create this manifest?", isPresented: $applyConfirmation, titleVisibility: .visible) {
            Button("Create", role: .destructive) { create() }
        } message: { Text("K9k will dry-run this exact YAML first, then create it through server-side apply if validation succeeds.") }
    }

    private func openFile() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.yaml]
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do { source = try String(contentsOf: url, encoding: .utf8) }
        catch { store.errorMessage = "K9k could not read the selected manifest: \(error.localizedDescription)" }
    }

    private func validate() {
        isWorking = true
        Task {
            defer { isWorking = false }
            do { _ = try await store.importManifest(type: type, source: source, confirm: false); validationMessage = "Validated by Kubernetes — no changes applied." }
            catch { validationMessage = "Validation failed."; store.errorMessage = error.localizedDescription }
        }
    }

    private func create() {
        isWorking = true
        Task {
            defer { isWorking = false }
            do { _ = try await store.importManifest(type: type, source: source, confirm: true); await store.loadResources(); dismiss() }
            catch { validationMessage = "Create failed."; store.errorMessage = error.localizedDescription }
        }
    }
}
