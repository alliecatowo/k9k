import AppKit
import SwiftUI

struct ManifestImportView: View {
    @Environment(ClusterStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State private var source = ""
    @State private var isWorking = false
    @State private var validationMessage: String?
    @State private var applyConfirmation = false

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Import Kubernetes Manifests").font(.headline)
                    Text("K9k resolves every document through active-cluster discovery, validates the complete set, then applies only after confirmation.").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button("Open YAML Files…") { openFiles() }.disabled(isWorking)
                Button("Close") { dismiss() }
            }.padding()
            Divider()
            SyntaxHighlightingEditor(source: $source, language: .yaml, isEditable: !isWorking).padding(10)
            Divider()
            HStack {
                Text(validationMessage ?? "Paste YAML or choose files/directories. Files are read recursively; namespace and name come from each manifest.")
                    .font(.caption).foregroundStyle(.secondary).lineLimit(2)
                Spacer()
                Button("Validate") { validate() }.disabled(source.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isWorking)
                Button("Apply \(documentLabel)…") { applyConfirmation = true }.disabled(source.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isWorking || store.isReadOnly)
            }.padding()
        }
        .frame(minWidth: 820, minHeight: 620)
        .confirmationDialog("Apply manifest batch?", isPresented: $applyConfirmation, titleVisibility: .visible) {
            Button("Apply \(documentLabel)", role: .destructive) { apply() }
        } message: { Text("K9k will resolve each document against live discovery, dry-run every document first, then server-side apply the exact batch without forcing ownership. Kubernetes does not provide a transaction across multiple resources, so a later write could fail after an earlier one succeeds.") }
    }

    private var documentLabel: String {
        let count = source.components(separatedBy: "\n---").count
        return count == 1 ? "Manifest" : "\(count) Documents"
    }

    private func openFiles() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.yaml]
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = true
        panel.canChooseFiles = true
        panel.prompt = "Import"
        guard panel.runModal() == .OK else { return }
        do {
            let files = try manifestFiles(from: panel.urls)
            guard !files.isEmpty else {
                validationMessage = "No .yaml or .yml files were found."
                return
            }
            source = try readManifestSources(files).joined(separator: "\n---\n")
            validationMessage = "Loaded \(files.count) YAML file\(files.count == 1 ? "" : "s"). Validate before applying."
        } catch { store.errorMessage = "K9k could not read the selected manifests: \(error.localizedDescription)" }
    }

    /// Mirrors the conventional manifest-directory workflow while avoiding
    /// hidden files and package contents (for example, a checked-in app or
    /// bundle). The helper remains authoritative for YAML validation and the
    /// maximum document count.
    private func manifestFiles(from selections: [URL]) throws -> [URL] {
        var results = Set<URL>()
        let manager = FileManager.default
        for selection in selections {
            var isDirectory: ObjCBool = false
            guard manager.fileExists(atPath: selection.path, isDirectory: &isDirectory) else { continue }
            if isDirectory.boolValue {
                guard let enumerator = manager.enumerator(
                    at: selection,
                    includingPropertiesForKeys: [.isRegularFileKey, .isDirectoryKey],
                    options: [.skipsHiddenFiles, .skipsPackageDescendants]
                ) else { continue }
                for case let url as URL in enumerator where isYAML(url) {
                    results.insert(url)
                }
            } else if isYAML(selection) {
                results.insert(selection)
            }
        }
        return results.sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
    }

    private func isYAML(_ url: URL) -> Bool {
        ["yaml", "yml"].contains(url.pathExtension.lowercased())
    }

    private func readManifestSources(_ files: [URL]) throws -> [String] {
        let maximumBytes = 8 * 1024 * 1024
        var totalBytes = 0
        var sources: [String] = []
        for file in files {
            let data = try Data(contentsOf: file)
            totalBytes += data.count
            guard totalBytes <= maximumBytes else {
                throw CocoaError(.fileReadTooLarge, userInfo: [NSFilePathErrorKey: file.path])
            }
            guard let text = String(data: data, encoding: .utf8) else {
                throw CocoaError(.fileReadInapplicableStringEncoding, userInfo: [NSFilePathErrorKey: file.path])
            }
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { sources.append(trimmed) }
        }
        return sources
    }

    private func validate() {
        isWorking = true
        Task {
            defer { isWorking = false }
            do {
                let result = try await store.importMixedManifests(source: source, confirm: false)
                validationMessage = "Validated \(result.items.count) document\(result.items.count == 1 ? "" : "s") by Kubernetes — no changes applied."
            }
            catch { validationMessage = "Validation failed."; store.errorMessage = error.localizedDescription }
        }
    }

    private func apply() {
        isWorking = true
        Task {
            defer { isWorking = false }
            do { _ = try await store.importMixedManifests(source: source, confirm: true); await store.loadResources(); dismiss() }
            catch { validationMessage = "Batch apply failed. Earlier documents may have been applied."; store.errorMessage = error.localizedDescription }
        }
    }
}
