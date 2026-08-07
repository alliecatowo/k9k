import AppKit
import SwiftUI

/// A deliberately read-only inspection sheet for one Helm v3 Secret-backed
/// revision. It starts with non-sensitive Chart.yaml metadata; rendering a
/// manifest, NOTES.txt, or configured values requires an intentional, visible
/// acknowledgement because all three commonly contain production secrets.
struct HelmReleaseInspectionView: View {
    let release: String
    let namespace: String
    let revision: HelmReleaseRevision

    @Environment(\.dismiss) private var dismiss
    @State private var client = CoreClient()
    @State private var inspection: HelmReleaseInspection?
    @State private var isLoading = false
    @State private var errorMessage: String?
    @State private var sensitiveAcknowledged = false

    var body: some View {
        NavigationStack {
            Group {
                if isLoading && inspection == nil {
                    ProgressView("Loading Helm release metadata…")
                } else if let inspection {
                    inspectionForm(inspection)
                } else if let errorMessage {
                    ContentUnavailableView("Helm Release Unavailable", systemImage: "exclamationmark.triangle", description: Text(errorMessage))
                } else {
                    ContentUnavailableView("Helm Release Unavailable", systemImage: "shippingbox")
                }
            }
            .navigationTitle("\(release) · Revision \(revision.revision)")
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        Task { await load(includeSensitive: inspection?.sensitive != nil) }
                    } label: {
                        Label("Refresh Helm release", systemImage: "arrow.clockwise")
                    }
                    .disabled(isLoading)
                    .help("Refresh Helm release inspection")
                }
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { dismiss() }
                }
            }
        }
        .frame(minWidth: 620, idealWidth: 800, minHeight: 560, idealHeight: 720)
        .task(id: revision.id) { await load(includeSensitive: false) }
        .onDisappear { client.stop() }
    }

    @ViewBuilder private func inspectionForm(_ inspection: HelmReleaseInspection) -> some View {
        Form {
            Section("Release") {
                LabeledContent("Namespace", value: inspection.namespace)
                LabeledContent("Revision", value: String(inspection.revision.revision))
                LabeledContent("Status", value: inspection.revision.status.capitalized)
                LabeledContent("Storage", value: inspection.revision.storageName)
            }

            Section("Chart") {
                LabeledContent("Name", value: inspection.chart.name)
                LabeledContent("Version", value: inspection.chart.version)
                optionalContent("App version", inspection.chart.appVersion)
                optionalContent("API version", inspection.chart.apiVersion)
                optionalContent("Type", inspection.chart.type)
                optionalContent("Kubernetes", inspection.chart.kubeVersion)
                if inspection.chart.deprecated {
                    LabeledContent("Status", value: "Deprecated")
                }
                optionalContent("Description", inspection.chart.description)
                if !inspection.chart.sources.isEmpty {
                    LabeledContent("Sources", value: inspection.chart.sources.joined(separator: ", "))
                        .textSelection(.enabled)
                }
                if !inspection.chart.keywords.isEmpty {
                    LabeledContent("Keywords", value: inspection.chart.keywords.joined(separator: ", "))
                }
            }

            if inspection.sensitiveContentAvailable {
                sensitiveDisclosure(inspection)
            }

            if let sensitive = inspection.sensitive {
                sensitiveSourceSection("Rendered Manifest", source: sensitive.manifest, language: .yaml, truncated: sensitive.manifestTruncated)
                sensitiveSourceSection("Release Notes", source: sensitive.notes, language: .yaml, truncated: sensitive.notesTruncated)
                sensitiveSourceSection("Configured Values", source: sensitive.valuesJSON, language: .json, truncated: sensitive.valuesTruncated)
            }
        }
        .formStyle(.grouped)
    }

    @ViewBuilder private func optionalContent(_ label: String, _ value: String?) -> some View {
        if let value, !value.isEmpty {
            LabeledContent(label, value: value).textSelection(.enabled)
        }
    }

    @ViewBuilder private func sensitiveDisclosure(_ inspection: HelmReleaseInspection) -> some View {
        Section("Sensitive Content") {
            if let sensitive = inspection.sensitive {
                Label(sensitive.warning, systemImage: "exclamationmark.shield")
                    .font(.callout)
                    .foregroundStyle(.orange)
                    .accessibilityLabel("Sensitive Helm content is displayed. \(sensitive.warning)")
            } else {
                Text("Rendered manifests, NOTES.txt, and configured values can contain credentials, tokens, endpoints, or other production-sensitive data.")
                    .foregroundStyle(.secondary)
                Toggle("I understand this may reveal sensitive production content", isOn: $sensitiveAcknowledged)
                    .toggleStyle(.switch)
                Button("Reveal Manifest, Notes, and Values") {
                    Task { await load(includeSensitive: true) }
                }
                .disabled(!sensitiveAcknowledged || isLoading)
                .accessibilityHint("Requires acknowledgement before requesting potentially sensitive Helm release content")
            }
        }
    }

    @ViewBuilder private func sensitiveSourceSection(_ title: String, source: String?, language: SyntaxHighlightedTextView.Language, truncated: Bool) -> some View {
        if let source, !source.isEmpty {
            Section(title) {
                HStack {
                    Text("Sensitive")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.orange)
                    Spacer()
                    Button("Copy") { copy(source) }
                        .controlSize(.small)
                }
                if truncated {
                    Text("This field was truncated to keep the inspection responsive. Copying returns the displayed portion only.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                SyntaxHighlightedTextView(source: source, language: language)
                    .frame(minHeight: 220, idealHeight: 300, maxHeight: 420)
                    .accessibilityLabel("Sensitive \(title)")
            }
        }
    }

    private func load(includeSensitive: Bool) async {
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }
        do {
            let envelope = try await client.request("helm.inspect", parameters: .object([
                "namespace": .string(namespace),
                "release": .string(release),
                "storageName": .string(revision.storageName),
                "revision": .number(Double(revision.revision)),
                "includeSensitive": .bool(includeSensitive),
                "acknowledgeSensitive": .bool(includeSensitive && sensitiveAcknowledged),
            ]))
            guard let result = envelope.result else {
                throw CoreError(code: "emptyResponse", message: "The helper returned no Helm inspection.")
            }
            inspection = try JSONDecoder.k9k.decode(HelmReleaseInspection.self, from: JSONEncoder().encode(result))
        } catch {
            errorMessage = "K9k could not inspect this Helm revision: \(error.localizedDescription)"
        }
    }

    private func copy(_ source: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(source, forType: .string)
    }
}
