import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// A local, packaged-chart Helm upgrade flow. K9k deliberately receives chart
/// bytes through the user-selected file panel instead of handing a filesystem
/// path to the helper; the helper accepts only bounded `.tgz` archive bytes.
struct HelmUpgradeView: View {
    let release: String
    let namespace: String
    let currentRevision: HelmReleaseRevision

    @Environment(\.dismiss) private var dismiss
    @State private var client = CoreClient()
    @State private var chartArchive: Data?
    @State private var chartFilename: String?
    @State private var valuesYAML = ""
    @State private var valuesMode = "reset"
    @State private var sensitiveAcknowledged = false
    @State private var plan: HelmUpgradePlan?
    @State private var isPlanning = false
    @State private var isUpgrading = false
    @State private var upgradeConfirmationPresented = false
    @State private var repositorySourcesPresented = false
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            Form {
                sourceSection
                valuesSection
                planSection
            }
            .formStyle(.grouped)
            .navigationTitle("Upgrade \(release)")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { dismiss() }
                        .disabled(isPlanning || isUpgrading)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Plan Upgrade") {
                        Task { await makePlan() }
                    }
                    .disabled(chartArchive == nil || !sensitiveAcknowledged || isPlanning || isUpgrading)
                    .help("Render a server-side dry-run before a Helm upgrade")
                }
            }
        }
        .frame(minWidth: 680, idealWidth: 860, minHeight: 620, idealHeight: 780)
        .confirmationDialog("Upgrade \(release) to \(plan?.chartName ?? "this chart")?", isPresented: $upgradeConfirmationPresented, titleVisibility: .visible) {
            Button("Upgrade", role: .destructive) {
                Task { await upgrade() }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Helm will create a new release revision from the exact chart and values shown in this plan. Hooks remain enabled; K9k will not wait for workload readiness.")
        }
        .onDisappear { client.stop() }
        .sheet(isPresented: $repositorySourcesPresented) {
            HelmRepositorySourcesView()
        }
    }

    private var sourceSection: some View {
        Section("Packaged Chart") {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text(chartFilename ?? "No chart selected")
                    Text("Only a local, user-selected `.tgz` chart is accepted. Repository, OCI, and Helm credential-store sources are intentionally not used here.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("Choose Chart…") { chooseChart() }
                    .disabled(isPlanning || isUpgrading)
            }
            Button("Inspect Repository Sources…") { repositorySourcesPresented = true }
                .disabled(isPlanning || isUpgrading)
            if let chartArchive {
                LabeledContent("Archive size", value: ByteCountFormatter.string(fromByteCount: Int64(chartArchive.count), countStyle: .file))
            }
            if let errorMessage {
                Label(errorMessage, systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.red)
                    .textSelection(.enabled)
            }
        }
    }

    private var valuesSection: some View {
        Section("Values") {
            Picker("Value strategy", selection: $valuesMode) {
                Text("Reset to chart defaults").tag("reset")
                Text("Reuse current values").tag("reuse")
                Text("Reset, then reuse current").tag("reset-then-reuse")
            }
            Text("Reset is the predictable default. Reuse options ask Helm to merge the stored release values with this chart and the YAML below.")
                .font(.caption)
                .foregroundStyle(.secondary)
            TextEditor(text: $valuesYAML)
                .font(.system(.body, design: .monospaced))
                .frame(minHeight: 130, idealHeight: 190)
                .overlay(alignment: .topLeading) {
                    if valuesYAML.isEmpty {
                        Text("Optional values.yaml overrides")
                            .foregroundStyle(.tertiary)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 8)
                            .allowsHitTesting(false)
                    }
                }
            Toggle("I understand the values and rendered upgrade plan can reveal sensitive production data", isOn: $sensitiveAcknowledged)
        }
    }

    @ViewBuilder private var planSection: some View {
        Section("Server-side Plan") {
            if isPlanning {
                ProgressView("Rendering Helm upgrade plan…")
            } else if let plan {
                LabeledContent("Chart", value: "\(plan.chartName) \(plan.chartVersion)")
                LabeledContent("Next revision", value: String(plan.nextRevision))
                LabeledContent("Value strategy", value: plan.valuesMode)
                Text("Sensitive rendered manifest — review this exact plan before upgrading.")
                    .font(.caption)
                    .foregroundStyle(.orange)
                SyntaxHighlightedTextView(source: plan.manifest, language: .yaml)
                    .frame(minHeight: 210, idealHeight: 300, maxHeight: 400)
                if let notes = plan.notes, !notes.isEmpty {
                    Text(notes).textSelection(.enabled)
                }
                Button("Upgrade This Planned Release…", role: .destructive) {
                    upgradeConfirmationPresented = true
                }
                .disabled(isUpgrading)
            } else {
                Text("Select a packaged chart, set values, acknowledge sensitive output, then render a server-side dry-run. Any source/value change requires a new plan.")
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func chooseChart() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.gzip]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let acquired = url.startAccessingSecurityScopedResource()
        defer {
            if acquired { url.stopAccessingSecurityScopedResource() }
        }
        do {
            let data = try Data(contentsOf: url, options: [.mappedIfSafe])
            guard !data.isEmpty, data.count <= 8 << 20 else {
                throw CoreError(code: "chartTooLarge", message: "Packaged charts must be between 1 byte and 8 MiB.")
            }
            chartArchive = data
            chartFilename = url.lastPathComponent
            plan = nil
            errorMessage = nil
        } catch {
            errorMessage = "K9k could not read that packaged chart: \(error.localizedDescription)"
        }
    }

    private func makePlan() async {
        guard chartArchive != nil else { return }
        isPlanning = true
        plan = nil
        errorMessage = nil
        defer { isPlanning = false }
        do {
            let envelope = try await client.request("helm.upgrade.plan", parameters: parameters(planDigest: nil, confirm: nil))
            guard let result = envelope.result else {
                throw CoreError(code: "emptyResponse", message: "The helper returned no Helm upgrade plan.")
            }
            plan = try JSONDecoder.k9k.decode(HelmUpgradePlan.self, from: JSONEncoder().encode(result))
        } catch {
            errorMessage = "K9k could not render this Helm upgrade plan: \(error.localizedDescription)"
        }
    }

    private func upgrade() async {
        guard let plan else { return }
        isUpgrading = true
        errorMessage = nil
        defer { isUpgrading = false }
        do {
            _ = try await client.request("helm.upgrade", parameters: parameters(planDigest: plan.planDigest, confirm: true))
            dismiss()
        } catch {
            errorMessage = "K9k could not start this Helm upgrade: \(error.localizedDescription)"
        }
    }

    private func parameters(planDigest: String?, confirm: Bool?) -> JSONValue {
        var result: [String: JSONValue] = [
            "namespace": .string(namespace),
            "release": .string(release),
            "expectedStorageName": .string(currentRevision.storageName),
            "expectedRevision": .number(Double(currentRevision.revision)),
            "chartArchiveBase64": .string(chartArchive?.base64EncodedString() ?? ""),
            "valuesYAML": .string(valuesYAML),
            "valuesMode": .string(valuesMode),
            "acknowledgeSensitive": .bool(sensitiveAcknowledged),
        ]
        if let planDigest { result["planDigest"] = .string(planDigest) }
        if let confirm { result["confirm"] = .bool(confirm) }
        return .object(result)
    }
}
