import AppKit
import SwiftUI

struct ResourceBrowserView: View {
    @Environment(ClusterStore.self) private var store
    @Binding var inspectorIsPresented: Bool
    @Binding var destructiveConfirmation: Bool
    @State private var sortOrder = [KeyPathComparator(\ResourceSummary.name)]

    var body: some View {
        @Bindable var store = store
        Group {
            if let type = store.selectedResourceType {
                let configuredColumns = store.customColumns(for: type)
                Table(store.visibleResources, selection: $store.selectedResources, sortOrder: $sortOrder) {
                    if configuredColumns.isEmpty {
                        TableColumn("Name", value: \.name) { resource in
                            VStack(alignment: .leading, spacing: 2) {
                                Text(resource.name).fontWeight(.medium)
                                if resource.namespace?.isEmpty == false { Text(resource.namespace!).font(.caption).foregroundStyle(.secondary) }
                            }
                        }
                        .width(min: 220, ideal: 280)
                        TableColumn("Status", value: \.status) { Text($0.status).foregroundStyle(statusColor($0.status)) }
                            .width(min: 100, ideal: 140)
                        TableColumn("Age", value: \.age) { Text($0.age).monospacedDigit() }
                            .width(min: 54, ideal: 70)
                        TableColumn("Kind") { Text($0.kind).foregroundStyle(.secondary) }
                            .width(min: 110, ideal: 150)
                    } else {
                        // A K9s view is a column layout, not a single opaque
                        // text field. `customColumns` excludes unsupported
                        // renderer-only definitions before this builder runs,
                        // so every visible column has a real native source.
                        ForEach(configuredColumns) { column in
                            TableColumn(column.title) { resource in
                                Text(column.value(for: resource))
                                    .foregroundStyle(column.source == .status ? statusColor(resource.status) : .primary)
                                    .monospacedDigit()
                                    .multilineTextAlignment(column.rightAligned ? .trailing : .leading)
                                    .frame(maxWidth: .infinity, alignment: column.rightAligned ? .trailing : .leading)
                            }
                            .width(min: column.title.count > 14 ? 140 : 84, ideal: column.title.count > 14 ? 190 : 120)
                        }
                    }
                }
                .tableStyle(.inset)
                .alternatingRowBackgrounds(.disabled)
                .scrollContentBackground(.hidden)
                .onChange(of: sortOrder) { _, newOrder in store.sortResources(using: newOrder) }
                .contextMenu(forSelectionType: ResourceSummary.ID.self) { selection in
                    Button("Copy Name") { store.copySelectedName() }
                    Divider()
                    Button("Delete…", role: .destructive) { destructiveConfirmation = true }
                        .disabled(!store.canDeleteSelected || selection.isEmpty)
                } primaryAction: { _ in inspectorIsPresented = true }
                .overlay { if store.isLoading { ProgressView().controlSize(.small) } }
                .navigationTitle(store.labelSelector == "owner=helm" && type.resource == "secrets" ? "Helm Releases" : type.kind)
            } else {
                ContentUnavailableView("No Resource Selected", systemImage: "cube.transparent", description: Text("Choose a Kubernetes resource from the resource catalog."))
            }
        }
        .safeAreaInset(edge: .top, spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "line.3.horizontal.decrease.circle")
                    .foregroundStyle(.secondary)
                TextField("Filter resource name, kind, or namespace", text: Bindable(store).searchText)
                    .textFieldStyle(.roundedBorder)
                if !store.searchText.isEmpty {
                    Button("Clear") { store.searchText = "" }
                        .buttonStyle(.borderless)
                }
                Menu("Export") {
                    Button("Copy Visible Rows as TSV") { copyVisibleRows() }
                    Divider()
                    Button("Save Visible Rows as JSON…") { saveVisibleRows(as: .json) }
                    Button("Save Visible Rows as CSV…") { saveVisibleRows(as: .csv) }
                    Button("Save Visible Rows as TSV…") { saveVisibleRows(as: .tsv) }
                    Divider()
                    Button("Save Current Window as PNG…") { saveCurrentWindowScreenshot() }
                }
                .menuStyle(.borderedButton)
                if !store.labelSelector.isEmpty || !store.fieldSelector.isEmpty {
                    Menu("Selectors") {
                        if !store.labelSelector.isEmpty { Text("Label: \(store.labelSelector)") }
                        if !store.fieldSelector.isEmpty { Text("Field: \(store.fieldSelector)") }
                        Button("Clear Selectors") {
                            store.clearSelectors()
                            Task { await store.loadResources() }
                        }
                    }
                    .menuStyle(.borderedButton)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 9)
            .background(WindowBackgroundShapeStyle.windowBackground)
        }
        .background(WindowBackgroundShapeStyle.windowBackground)
    }

    private func statusColor(_ status: String) -> Color {
        switch status.lowercased() {
        case "running", "active", "bound", "ready": .green
        case "failed", "error", "unknown": .red
        case "pending", "terminating": .orange
        default: .secondary
        }
    }

    private enum ExportFormat: String { case json, csv, tsv }

    private func copyVisibleRows() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(tabularRows(separator: "\t"), forType: .string)
    }

    private func saveVisibleRows(as format: ExportFormat) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "k9k-\(store.selectedResourceType?.resource ?? "resources").\(format.rawValue)"
        panel.allowedContentTypes = switch format {
        case .json: [.json]
        case .csv: [.commaSeparatedText]
        case .tsv: [.tabSeparatedText]
        }
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let contents: String
        switch format {
        case .json:
            contents = prettyJSONRows()
        case .csv:
            contents = tabularRows(separator: ",")
        case .tsv:
            contents = tabularRows(separator: "\t")
        }
        do {
            try contents.write(to: url, atomically: true, encoding: .utf8)
        } catch {
            store.errorMessage = "K9k could not save the resource export: \(error.localizedDescription)"
        }
    }

    private func saveCurrentWindowScreenshot() {
        let resource = store.selectedResourceType?.resource ?? "resources"
        Task {
            do {
                try await WindowScreenshotExporter.saveCurrentWindow(named: "k9k-\(resource)-window.png")
            } catch {
                store.errorMessage = "K9k could not save the window screenshot: \(error.localizedDescription)"
            }
        }
    }

    private func tabularRows(separator: String) -> String {
        let headers = ["Name", "Namespace", "Kind", "Status", "Age"]
        let rows = store.visibleResources.map { [$0.name, $0.namespace ?? "", $0.kind, $0.status, $0.age] }
        return ([headers] + rows).map { $0.map { escaped($0, separator: separator) }.joined(separator: separator) }.joined(separator: "\n") + "\n"
    }

    private func escaped(_ value: String, separator: String) -> String {
        guard separator == "," else { return value.replacing("\t", with: " ").replacing("\n", with: " ") }
        guard value.contains(",") || value.contains("\"") || value.contains("\n") else { return value }
        return "\"\(value.replacing("\"", with: "\"\""))\""
    }

    private func prettyJSONRows() -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(store.visibleResources) else { return "[]\n" }
        return String(decoding: data, as: UTF8.self) + "\n"
    }
}
