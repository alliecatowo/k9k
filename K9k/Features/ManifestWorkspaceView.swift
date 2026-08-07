import AppKit
import SwiftUI

/// A native manifest-directory workspace. It deliberately treats files as
/// local source material only: discovery, validation, UID pinning, and every
/// Kubernetes mutation remain in the bundled client-go helper.
struct ManifestWorkspaceView: View {
    @Environment(ClusterStore.self) private var store
    @Environment(\.dismiss) private var dismiss

    @State private var workspaceRoot: ManifestWorkspaceEntry?
    @State private var selectedEntryIDs = Set<String>()
    @State private var selectedFiles: [URL] = []
    @State private var source = ""
    @State private var statusMessage: String?
    @State private var isWorking = false
    @State private var applyConfirmation = false
    @State private var deleteConfirmation = false
    @State private var appliedBatch: ManifestBatchApplyResult?
    @State private var diffResult: ManifestDiffResult?
    @State private var diffPresented = false
    @State private var validatedBatch: ManifestBatchApplyResult?
    @State private var batchPreviewPresented = false

    var body: some View {
        NavigationSplitView {
            VStack(spacing: 0) {
                HStack {
                    Button("Open Manifest Directory…") { openWorkspace() }
                        .disabled(isWorking || appliedBatch != nil)
                    Button("Reload from Disk") { reloadWorkspace() }
                        .disabled(workspaceRoot == nil || isWorking || appliedBatch != nil)
                        .help("Rescan the selected local workspace. K9k never watches or changes files in the background.")
                    Spacer()
                }
                .padding()
                Divider()

                if let root = workspaceRoot {
                    List(selection: $selectedEntryIDs) {
                        OutlineGroup([root], children: \.children) { entry in
                            Label(entry.name, systemImage: entry.isDirectory ? "folder" : "doc.text")
                                .tag(entry.id)
                        }
                    }
                    .listStyle(.sidebar)
                    .onChange(of: selectedEntryIDs) { _, values in
                        let entries = values.compactMap(root.entry(id:))
                        select(entries)
                    }
                } else {
                    ContentUnavailableView("No Manifest Workspace", systemImage: "folder", description: Text("Choose a YAML file or directory to browse its manifest hierarchy."))
                }
            }
            .navigationSplitViewColumnWidth(min: 260, ideal: 310, max: 400)
        } detail: {
            VStack(spacing: 0) {
                HStack(spacing: 12) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(workspaceTitle).font(.headline)
                        Text(scopeDescription)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    }
                    Spacer()
                    if let selectedEntry, let parent = workspaceRoot?.parentID(of: selectedEntry.id) {
                        Button("Up") { selectedEntryIDs = [parent] }
                            .help("Select the containing manifest directory")
                    }
                    if let root = workspaceRoot {
                        Button("Reveal") { NSWorkspace.shared.activateFileViewerSelecting([selectedEntry?.url ?? root.url]) }
                            .help("Reveal the selected manifest or workspace in Finder")
                    }
                    Button("Close") { dismiss() }
                }
                .padding()
                Divider()

                if source.isEmpty {
                    ContentUnavailableView("Select a Manifest", systemImage: "doc.text.magnifyingglass", description: Text("Select a YAML file to operate on it, or a directory to operate on every YAML file beneath it."))
                } else {
                    SyntaxHighlightingEditor(source: .constant(source), language: .yaml, isEditable: false)
                        .padding(12)
                        .background(.background)
                }

                Divider()
                HStack(spacing: 10) {
                    Text(statusMessage ?? "K9k validates selected YAML through active-cluster discovery before applying. A directory operation is never transactional.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                    Spacer()
                    if let appliedBatch {
                        Menu("Follow Result") {
                            ForEach(appliedBatch.items, id: \.identity) { document in
                                Button("\(document.identity.kind) · \(document.identity.namespace ?? "cluster") / \(document.identity.name)") {
                                    Task { _ = await store.openImportedManifest(document) }
                                }
                            }
                        }
                        Button("Prepare Removal…") { prepareRemoval(appliedBatch.items.map(\.identity)) }
                            .disabled(isWorking || store.isReadOnly || appliedBatch.items.contains { $0.identity.uid.isEmpty })
                    } else {
                        if let validatedBatch {
                            Button("Review Preview") { batchPreviewPresented = true }
                                .help("Review the exact Kubernetes identities returned by dry-run validation")
                        }
                        Button("Compare with Live") { compareWithLive() }
                            .disabled(isWorking || source.isEmpty || selectedFiles.count != 1)
                            .help("Compare exactly one selected YAML file to its UID-pinned live object")
                        Button("Validate") { validate() }
                            .disabled(isWorking || source.isEmpty)
                        Button("Apply Selected Scope…") { applyConfirmation = true }
                            .keyboardShortcut(.defaultAction)
                            .disabled(isWorking || source.isEmpty || store.isReadOnly)
                    }
                }
                .padding()
            }
        }
        .frame(minWidth: 980, minHeight: 680)
        .confirmationDialog("Apply selected manifest scope?", isPresented: $applyConfirmation, titleVisibility: .visible) {
            Button("Apply \(scopeOperationLabel)", role: .destructive) { apply() }
        } message: {
            Text("K9k will resolve every selected document through live discovery and dry-run the complete scope before non-forced server-side apply. Kubernetes cannot transact arbitrary resources, so a later write may fail after an earlier write succeeds.")
        }
        .confirmationDialog("Delete imported manifest scope?", isPresented: $deleteConfirmation, titleVisibility: .visible) {
            Button("Delete \(appliedBatch?.items.count ?? 0) Imported Objects", role: .destructive) { deleteAppliedBatch() }
        } message: {
            Text("K9k checked delete access, existence, complete resource identity, and UID for every result. Deletes are UID-preconditioned, but Kubernetes cannot make this cross-resource operation atomic.")
        }
        .sheet(isPresented: $diffPresented) {
            if let diffResult { ManifestDiffView(result: diffResult) }
        }
        .sheet(isPresented: $batchPreviewPresented) {
            if let validatedBatch { ManifestBatchPreviewView(result: validatedBatch) }
        }
    }

    private var workspaceTitle: String {
        guard let root = workspaceRoot else { return "Manifest Workspace" }
        return root.url.lastPathComponent
    }

    private var scopeDescription: String {
        guard !selectedFiles.isEmpty else { return "Choose a file or directory from the hierarchy." }
        let names = selectedFiles.prefix(2).map(\.lastPathComponent).joined(separator: ", ")
        let tail = selectedFiles.count > 2 ? " + \(selectedFiles.count - 2) more" : ""
        return "\(selectedFiles.count) YAML file\(selectedFiles.count == 1 ? "" : "s"): \(names)\(tail)"
    }

    private var scopeOperationLabel: String {
        selectedFiles.count == 1 ? "Manifest" : "\(selectedFiles.count) YAML Files"
    }

    private var selectedEntry: ManifestWorkspaceEntry? {
        guard selectedEntryIDs.count == 1,
              let id = selectedEntryIDs.first else { return nil }
        return workspaceRoot?.entry(id: id)
    }

    private func openWorkspace() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Open"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            guard let root = try ManifestWorkspaceEntry.scan(url: url) else {
                statusMessage = "No .yaml or .yml files were found in the selected location."
                return
            }
            workspaceRoot = root
            appliedBatch = nil
            validatedBatch = nil
            selectedEntryIDs = [root.id]
            select([root])
        } catch {
            statusMessage = "K9k could not read the selected workspace."
            store.errorMessage = error.localizedDescription
        }
    }

    private func reloadWorkspace() {
        guard let existing = workspaceRoot else { return }
        let preservedSelection = selectedEntryIDs
        do {
            guard let reloaded = try ManifestWorkspaceEntry.scan(url: existing.url) else {
                workspaceRoot = nil
                selectedEntryIDs = []
                selectedFiles = []
                source = ""
                validatedBatch = nil
                statusMessage = "No .yaml or .yml files remain in this workspace."
                return
            }
            workspaceRoot = reloaded
            let retained = Set(preservedSelection.filter { reloaded.entry(id: $0) != nil })
            selectedEntryIDs = retained.isEmpty ? [reloaded.id] : retained
            select(selectedEntryIDs.compactMap(reloaded.entry(id:)))
            validatedBatch = nil
            statusMessage = "Reloaded the local workspace. Select files with Command-click to change the batch scope."
        } catch {
            statusMessage = "K9k could not reload the local workspace; the current preview was kept."
            store.errorMessage = error.localizedDescription
        }
    }

    private func select(_ entries: [ManifestWorkspaceEntry]) {
        do {
            let files = Array(Set(entries.flatMap(\.descendantFiles))).sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
            selectedFiles = files
            source = try readSources(files)
            validatedBatch = nil
            statusMessage = "Selected \(entries.count) item\(entries.count == 1 ? "" : "s") containing \(files.count) YAML file\(files.count == 1 ? "" : "s")."
        } catch {
            source = ""
            selectedFiles = []
            statusMessage = "K9k could not load the selected YAML."
            store.errorMessage = error.localizedDescription
        }
    }

    private func readSources(_ files: [URL]) throws -> String {
        let maxBytes = 8 * 1024 * 1024
        var totalBytes = 0
        var parts: [String] = []
        for file in files.sorted(by: { $0.path.localizedStandardCompare($1.path) == .orderedAscending }) {
            let data = try Data(contentsOf: file)
            totalBytes += data.count
            guard totalBytes <= maxBytes else {
                throw CocoaError(.fileReadTooLarge, userInfo: [NSFilePathErrorKey: file.path])
            }
            guard let text = String(data: data, encoding: .utf8) else {
                throw CocoaError(.fileReadInapplicableStringEncoding, userInfo: [NSFilePathErrorKey: file.path])
            }
            if !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { parts.append(text) }
        }
        return parts.joined(separator: "\n---\n")
    }

    private func validate() {
        isWorking = true
        Task {
            defer { isWorking = false }
            do {
                let result = try await store.importMixedManifests(source: source, confirm: false)
                validatedBatch = result
                statusMessage = "Validated \(result.items.count) Kubernetes document\(result.items.count == 1 ? "" : "s") — no changes applied."
            } catch {
                statusMessage = "Validation failed; no changes were applied."
                store.errorMessage = error.localizedDescription
            }
        }
    }

    private func compareWithLive() {
        isWorking = true
        Task {
            defer { isWorking = false }
            do {
                diffResult = try await store.diffImportedManifest(source: source)
                diffPresented = true
            } catch {
                statusMessage = "Comparison failed. Select exactly one live YAML object and verify it is served by this cluster."
                store.errorMessage = error.localizedDescription
            }
        }
    }

    private func apply() {
        isWorking = true
        Task {
            defer { isWorking = false }
            do {
                let result = try await store.importMixedManifests(source: source, confirm: true)
                appliedBatch = result
                validatedBatch = result
                statusMessage = "Applied \(result.items.count) object\(result.items.count == 1 ? "" : "s"). Follow a result or prepare a UID-pinned removal of this exact scope."
                await store.loadResources()
            } catch {
                statusMessage = "Apply failed. Earlier documents may have been applied."
                store.errorMessage = error.localizedDescription
            }
        }
    }

    private func prepareRemoval(_ identities: [ManifestIdentity]) {
        isWorking = true
        Task {
            defer { isWorking = false }
            do {
                let result = try await store.deleteImportedManifestBatch(identities, confirm: false)
                statusMessage = "Deletion preflight passed for \(result.items.count) object\(result.items.count == 1 ? "" : "s"). No objects were removed."
                deleteConfirmation = true
            } catch {
                statusMessage = "Deletion preflight failed; no objects were removed."
                store.errorMessage = error.localizedDescription
            }
        }
    }

    private func deleteAppliedBatch() {
        guard let appliedBatch else { return }
        isWorking = true
        Task {
            defer { isWorking = false }
            do {
                let result = try await store.deleteImportedManifestBatch(appliedBatch.items.map(\.identity), confirm: true)
                self.appliedBatch = nil
                statusMessage = "Deleted \(result.items.count) imported object\(result.items.count == 1 ? "" : "s")."
                await store.loadResources()
            } catch {
                statusMessage = "Deletion failed. Earlier objects may already be deleted; refresh the cluster before retrying."
                store.errorMessage = error.localizedDescription
            }
        }
    }
}

private struct ManifestWorkspaceEntry: Identifiable, Hashable {
    let url: URL
    let isDirectory: Bool
    let children: [ManifestWorkspaceEntry]?

    var id: String { url.standardizedFileURL.path }
    var name: String { url.lastPathComponent }

    var descendantFiles: [URL] {
        if !isDirectory { return [url] }
        return (children ?? []).flatMap(\.descendantFiles)
    }

    func entry(id: String) -> ManifestWorkspaceEntry? {
        if self.id == id { return self }
        for child in children ?? [] {
            if let found = child.entry(id: id) { return found }
        }
        return nil
    }

    /// Returns the visible hierarchy parent without consulting the filesystem.
    /// This keeps directory navigation stable until an operator explicitly
    /// chooses Reload from Disk.
    func parentID(of targetID: String) -> String? {
        for child in children ?? [] {
            if child.id == targetID { return id }
            if let parent = child.parentID(of: targetID) { return parent }
        }
        return nil
    }

    static func scan(url: URL) throws -> ManifestWorkspaceEntry? {
        let values = try url.resourceValues(forKeys: [.isDirectoryKey, .isRegularFileKey])
        if values.isDirectory == true {
            let manager = FileManager.default
            let children = try manager.contentsOfDirectory(
                at: url,
                includingPropertiesForKeys: [.isDirectoryKey, .isRegularFileKey, .isPackageKey],
                options: [.skipsHiddenFiles, .skipsPackageDescendants]
            )
            let nested = try children.compactMap(scan(url:))
                .sorted { lhs, rhs in
                    if lhs.isDirectory != rhs.isDirectory { return lhs.isDirectory }
                    return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
                }
            guard !nested.isEmpty else { return nil }
            return ManifestWorkspaceEntry(url: url, isDirectory: true, children: nested)
        }
        guard values.isRegularFile == true, ["yaml", "yml"].contains(url.pathExtension.lowercased()) else { return nil }
        return ManifestWorkspaceEntry(url: url, isDirectory: false, children: nil)
    }
}

/// A compact diagnostic surface for a batch dry-run. It exposes the exact
/// resource identities Kubernetes returned, rather than reducing a failed or
/// surprising directory selection to an opaque count.
private struct ManifestBatchPreviewView: View {
    @Environment(\.dismiss) private var dismiss
    let result: ManifestBatchApplyResult

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Manifest Batch Preview").font(.headline)
                    Text("Kubernetes validated these \(result.items.count) document\(result.items.count == 1 ? "" : "s"); no changes were applied.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("Close") { dismiss() }
            }
            .padding()
            Divider()
            List(result.items, id: \.identity) { document in
                let identity = document.identity
                VStack(alignment: .leading, spacing: 4) {
                    Text("\(identity.kind) · \(identity.namespace ?? "cluster") / \(identity.name)")
                        .font(.body.weight(.medium))
                    Text("\(identity.group.map { "\($0)/" } ?? "")\(identity.version)/\(identity.resource) · \(identity.namespaced ? "namespaced" : "cluster-scoped")")
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(.secondary)
                    if !identity.uid.isEmpty {
                        Text("UID: \(identity.uid)")
                            .font(.system(.caption2, design: .monospaced))
                            .foregroundStyle(.tertiary)
                            .textSelection(.enabled)
                    }
                }
                .padding(.vertical, 3)
            }
            .listStyle(.inset)
        }
        .frame(minWidth: 650, minHeight: 420)
    }
}
