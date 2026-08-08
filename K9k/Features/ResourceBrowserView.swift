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
                let customColumns = store.customColumns(for: type)
                let columns = customColumns.isEmpty ? K9sViewColumn.nativeColumns(for: type) : customColumns
                Table(store.visibleResources, selection: $store.selectedResources, sortOrder: $sortOrder) {
                    // Native resource layouts and K9s custom views share the
                    // same Table rendering path. No concatenated pseudo-cell
                    // or unsupported empty renderer columns are introduced.
                    TableColumnForEach(columns) { column in
                        TableColumn(column.title) { resource in
                            browserCell(column, resource: resource, showsNamespaceSubtitle: customColumns.isEmpty)
                        }
                        .width(min: columnMinimumWidth(column), ideal: columnIdealWidth(column))
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

    /// `TableColumn` uses a deeply generic builder. Type-erasing this small
    /// runtime-configured cell keeps custom K9s view columns scalable without
    /// making Swift's type checker re-solve every source-kind combination.
    private func browserCell(_ column: K9sViewColumn, resource: ResourceSummary, showsNamespaceSubtitle: Bool) -> AnyView {
        if case .name = column.source {
            return AnyView(VStack(alignment: .leading, spacing: 2) {
                Text(resource.name).fontWeight(.medium)
                if showsNamespaceSubtitle, resource.namespace?.isEmpty == false {
                    Text(resource.namespace!).font(.caption).foregroundStyle(.secondary)
                }
            })
        } else {
            return AnyView(Text(column.value(for: resource))
                .foregroundStyle(column.source == .status ? statusColor(resource.status) : .primary)
                .monospacedDigit()
                .multilineTextAlignment(column.rightAligned ? .trailing : .leading)
                .frame(maxWidth: .infinity, alignment: column.rightAligned ? .trailing : .leading))
        }
    }

    private func columnMinimumWidth(_ column: K9sViewColumn) -> CGFloat {
        switch column.source {
        case .name: 220
        case .labels: 180
        default: column.title.count > 14 ? 140 : 84
        }
    }

    private func columnIdealWidth(_ column: K9sViewColumn) -> CGFloat {
        switch column.source {
        case .name: 280
        case .labels: 260
        default: column.title.count > 14 ? 190 : 120
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
