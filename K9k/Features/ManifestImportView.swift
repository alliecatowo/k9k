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
                    Text("Import \(type.kind) Manifests").font(.headline)
                    Text("K9k validates every document against the selected cluster before it applies anything.").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button("Open YAML Files…") { openFiles() }.disabled(isWorking)
                Button("Close") { dismiss() }
            }.padding()
            Divider()
            SyntaxHighlightingEditor(source: $source, language: .yaml, isEditable: !isWorking).padding(10)
            Divider()
            HStack {
                Text(validationMessage ?? "Paste one or more YAML documents, or select YAML files. Namespace and name come from each manifest.")
                    .font(.caption).foregroundStyle(.secondary).lineLimit(2)
                Spacer()
                Button("Validate") { validate() }.disabled(source.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isWorking)
                Button("Apply \(documentLabel)…") { applyConfirmation = true }.disabled(source.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isWorking || store.isReadOnly)
            }.padding()
        }
        .frame(minWidth: 820, minHeight: 620)
        .confirmationDialog("Apply manifest batch?", isPresented: $applyConfirmation, titleVisibility: .visible) {
            Button("Apply \(documentLabel)", role: .destructive) { apply() }
        } message: { Text("K9k will dry-run every document first, then server-side apply the exact batch without forcing ownership. Kubernetes does not provide a transaction across multiple resources, so a later write could fail after an earlier one succeeds.") }
    }

    private var documentLabel: String {
        let count = source.components(separatedBy: "\n---").count
        return count == 1 ? "Manifest" : "\(count) Documents"
    }

    private func openFiles() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.yaml]
        panel.allowsMultipleSelection = true
        guard panel.runModal() == .OK else { return }
        do {
            source = try panel.urls.map { try String(contentsOf: $0, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
                .joined(separator: "\n---\n")
        } catch { store.errorMessage = "K9k could not read the selected manifests: \(error.localizedDescription)" }
    }

    private func validate() {
        isWorking = true
        Task {
            defer { isWorking = false }
            do {
                let result = try await store.importManifestBatch(type: type, source: source, confirm: false)
                validationMessage = "Validated \(result.items.count) document\(result.items.count == 1 ? "" : "s") by Kubernetes — no changes applied."
            }
            catch { validationMessage = "Validation failed."; store.errorMessage = error.localizedDescription }
        }
    }

    private func apply() {
        isWorking = true
        Task {
            defer { isWorking = false }
            do { _ = try await store.importManifestBatch(type: type, source: source, confirm: true); await store.loadResources(); dismiss() }
            catch { validationMessage = "Batch apply failed. Earlier documents may have been applied."; store.errorMessage = error.localizedDescription }
        }
    }
}
