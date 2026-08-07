import SwiftUI

/// A native, read-only revision timeline for the Helm Secret currently being
/// inspected. Keeping an independent request client here avoids coupling the
/// resource browser's watch lifecycle to a one-shot history lookup.
struct HelmReleaseHistorySection: View {
    let release: String
    let namespace: String

    @State private var client = CoreClient()
    @State private var history: HelmReleaseHistory?
    @State private var isLoading = false
    @State private var errorMessage: String?
    @State private var selectedRevision: HelmReleaseRevision?

    var body: some View {
        Section("Helm History") {
            if isLoading && history == nil {
                LabeledContent("Revisions") { ProgressView().controlSize(.small) }
            } else if let history {
                if history.revisions.isEmpty {
                    Text("No Helm storage revisions were found for this release.")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(history.revisions) { revision in
                        Button {
                            selectedRevision = revision
                        } label: {
                            HStack(alignment: .firstTextBaseline, spacing: 10) {
                                Text(revision.revision == 0 ? "Revision unknown" : "Revision \(revision.revision)")
                                    .fontWeight(.medium)
                                Text(revision.status.capitalized)
                                    .font(.caption)
                                    .foregroundStyle(statusColor(revision.status))
                                Spacer(minLength: 8)
                                Text(revision.age.isEmpty ? revision.createdAt.formatted(date: .abbreviated, time: .shortened) : revision.age)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                Image(systemName: "chevron.right")
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(.tertiary)
                            }
                        }
                        .buttonStyle(.plain)
                        .disabled(revision.revision == 0)
                        .accessibilityElement(children: .combine)
                        .accessibilityLabel("Inspect Helm \(release), revision \(revision.revision == 0 ? "unknown" : String(revision.revision)), \(revision.status)")
                        .accessibilityHint(revision.revision == 0 ? "This legacy storage object has no usable revision number" : "Opens a read-only Helm release inspection")
                    }
                }
                if history.truncated {
                    Text("Showing the newest \(history.revisions.count) of \(history.total) stored revisions.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Text("Select a revision to inspect chart metadata. Manifests, notes, and values require an explicit sensitive-content acknowledgement.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else if let errorMessage {
                LabeledContent("History", value: "Unavailable")
                Text(errorMessage).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                Button("Try Again") { Task { await load() } }
            } else {
                Button("Load Helm History") { Task { await load() } }
                    .accessibilityHint("Loads bounded Helm storage metadata for this release")
            }
        }
        .onDisappear { client.stop() }
        .sheet(item: $selectedRevision) { revision in
            HelmReleaseInspectionView(
                release: release,
                namespace: namespace,
                revision: revision,
                currentRevision: history?.revisions.first(where: { $0.revision > 0 })
            )
        }
    }

    private func load() async {
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }
        do {
            let envelope = try await client.request("helm.history", parameters: .object([
                "namespace": .string(namespace),
                "release": .string(release),
            ]))
            guard let result = envelope.result else {
                throw CoreError(code: "emptyResponse", message: "The helper returned no Helm history.")
            }
            history = try JSONDecoder.k9k.decode(HelmReleaseHistory.self, from: JSONEncoder().encode(result))
        } catch {
            history = nil
            errorMessage = "K9k could not load Helm history: \(error.localizedDescription)"
        }
    }

    private func statusColor(_ status: String) -> Color {
        switch status.lowercased() {
        case "deployed": .green
        case "failed", "uninstalling": .red
        case "pending-install", "pending-upgrade", "pending-rollback": .orange
        case "superseded", "uninstalled": .secondary
        default: .secondary
        }
    }
}
