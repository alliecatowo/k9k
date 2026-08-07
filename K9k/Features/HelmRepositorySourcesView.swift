import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// Inspects an explicitly selected Helm repository configuration without
/// loading registry config, revealing credentials, or contacting any server.
struct HelmRepositorySourcesView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var client = CoreClient()
    @State private var inspection: HelmRepositoryInspection?
    @State private var filename: String?
    @State private var isLoading = false
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Text("Choose a Helm `repositories.yaml` file to inspect public repository names and credential-free HTTP(S) endpoints. K9k never reads registry credentials, displays passwords/tokens, or fetches a chart from this screen.")
                        .foregroundStyle(.secondary)
                    Button("Choose Repository Configuration…") { chooseConfiguration() }
                        .disabled(isLoading)
                }
                if let filename {
                    Section("Selected File") { Text(filename).textSelection(.enabled) }
                }
                if isLoading {
                    Section { ProgressView("Inspecting repository metadata…") }
                }
                if let inspection {
                    Section("Available Sources") {
                        if inspection.repositories.isEmpty {
                            Text("No credential-free HTTP(S) repositories were found.")
                                .foregroundStyle(.secondary)
                        }
                        ForEach(inspection.repositories) { repository in
                            LabeledContent(repository.name, value: repository.url)
                                .textSelection(.enabled)
                        }
                    }
                    if !inspection.warnings.isEmpty {
                        Section("Ignored Entries") {
                            ForEach(inspection.warnings, id: \.self) { warning in
                                Label(warning, systemImage: "exclamationmark.shield")
                                    .foregroundStyle(.orange)
                            }
                        }
                    }
                }
                if let errorMessage {
                    Section("Unavailable") {
                        Label(errorMessage, systemImage: "exclamationmark.triangle")
                            .foregroundStyle(.red)
                            .textSelection(.enabled)
                    }
                }
            }
            .navigationTitle("Helm Repository Sources")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { dismiss() }
                }
            }
        }
        .frame(minWidth: 620, idealWidth: 760, minHeight: 430)
        .onDisappear { client.stop() }
    }

    private func chooseConfiguration() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.yaml]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let acquired = url.startAccessingSecurityScopedResource()
        defer {
            if acquired { url.stopAccessingSecurityScopedResource() }
        }
        do {
            let data = try Data(contentsOf: url, options: [.mappedIfSafe])
            guard data.count <= 1 << 20, let document = String(data: data, encoding: .utf8) else {
                throw CoreError(code: "invalidRepositoryConfig", message: "Repository configuration must be UTF-8 YAML no larger than 1 MiB.")
            }
            filename = url.lastPathComponent
            Task { await inspect(document) }
        } catch {
            errorMessage = "K9k could not read that repository configuration: \(error.localizedDescription)"
        }
    }

    private func inspect(_ document: String) async {
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }
        do {
            let envelope = try await client.request("helm.repository.inspect", parameters: .object(["document": .string(document)]))
            guard let result = envelope.result else {
                throw CoreError(code: "emptyResponse", message: "The helper returned no repository metadata.")
            }
            inspection = try JSONDecoder.k9k.decode(HelmRepositoryInspection.self, from: JSONEncoder().encode(result))
        } catch {
            inspection = nil
            errorMessage = "K9k could not inspect this repository configuration: \(error.localizedDescription)"
        }
    }
}
