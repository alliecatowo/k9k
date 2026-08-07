import AppKit
import SwiftUI

/// Native review surface for the exact server-side-apply preview.  It keeps
/// the unified form available for support/copy-paste while exposing semantic
/// field paths so operators do not have to mentally parse YAML indentation.
struct ManifestDiffView: View {
    enum Presentation: String, CaseIterable, Identifiable {
        case unified = "Unified Diff"
        case structured = "Changed Fields"
        var id: String { rawValue }
    }

    @Environment(\.dismiss) private var dismiss
    let result: ManifestDiffResult
    @State private var presentation: Presentation = .unified

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Image(systemName: result.changed ? "arrow.left.arrow.right" : "checkmark.circle")
                    .foregroundStyle(result.changed ? .secondary : .green)
                VStack(alignment: .leading, spacing: 3) {
                    Text("Manifest Diff").font(.headline)
                    Text("\(result.identity.kind) · \(result.identity.namespace ?? "cluster") / \(result.identity.name)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Text(result.changed ? "\(result.changes.count) change\(result.changes.count == 1 ? "" : "s")" : "No changes")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(result.changed ? .secondary : .green)
                Button("Close") { dismiss() }
            }
            .padding()

            Divider()
            Picker("Diff presentation", selection: $presentation) {
                ForEach(Presentation.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .padding(.horizontal)
            .padding(.vertical, 10)
            Divider()

            Group {
                switch presentation {
                case .unified:
                    if result.changed {
                        SyntaxHighlightedTextView(source: result.diff, language: .yaml)
                            .background(.background)
                    } else {
                        ContentUnavailableView("No Manifest Changes", systemImage: "checkmark.circle", description: Text("The imported YAML produces the same editable object as the current server state."))
                    }
                case .structured:
                    structuredChanges
                }
            }

            Divider()
            HStack {
                Text("Live object and preview are UID-pinned. Preview uses non-forced server-side apply dry run; nothing was changed.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                Spacer()
                Button("Copy Diff") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(result.diff, forType: .string)
                }
                .disabled(!result.changed || result.diff.isEmpty)
            }
            .padding()
        }
        .frame(minWidth: 860, minHeight: 620)
    }

    private var structuredChanges: some View {
        Group {
            if result.changes.isEmpty {
                ContentUnavailableView("No Manifest Changes", systemImage: "checkmark.circle", description: Text("The imported YAML produces the same editable object as the current server state."))
            } else {
                List(result.changes) { change in
                    HStack(alignment: .top, spacing: 10) {
                        Image(systemName: symbol(for: change.operation))
                            .foregroundStyle(color(for: change.operation))
                            .frame(width: 18)
                        VStack(alignment: .leading, spacing: 5) {
                            HStack {
                                Text(change.path).font(.system(.body, design: .monospaced))
                                Text(change.operation.capitalized)
                                    .font(.caption.weight(.medium))
                                    .foregroundStyle(color(for: change.operation))
                            }
                            if let live = change.live {
                                Text("Live: \(live)").font(.system(.caption, design: .monospaced)).foregroundStyle(.secondary).textSelection(.enabled)
                            }
                            if let preview = change.preview {
                                Text("Preview: \(preview)").font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                            }
                        }
                    }
                    .padding(.vertical, 3)
                }
                .listStyle(.inset)
            }
        }
        .overlay(alignment: .bottomTrailing) {
            if result.truncated {
                Label("Showing the first 1,000 changed fields", systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .padding(8)
                    .background(.regularMaterial, in: Capsule())
                    .padding()
            }
        }
    }

    private func symbol(for operation: String) -> String {
        switch operation { case "add": "plus.circle"; case "remove": "minus.circle"; default: "arrow.triangle.2.circlepath" }
    }

    private func color(for operation: String) -> Color {
        switch operation { case "add": .green; case "remove": .red; default: .orange }
    }
}
