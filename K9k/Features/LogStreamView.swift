import AppKit
import SwiftUI

struct LogStreamView: View {
    @Environment(ClusterStore.self) private var store
    let resource: ResourceSummary
    @Environment(\.dismiss) private var dismiss
    @State private var isFollowing = true
    @State private var selectedContainer = ""
    @State private var previous = false
    @State private var timestamps = true
    @State private var tailLines = 500
    @State private var sinceSeconds: Int?
    @State private var filter = ""
    @State private var wrapsLines = false

    private var containers: [String] { resource.raw?.objectValue?["spec"]?.objectValue?["containers"]?.arrayValue?.compactMap { $0.objectValue?["name"]?.stringValue } ?? [] }
    private var visibleLines: [String] {
        let query = filter.trimmingCharacters(in: .whitespacesAndNewlines)
        return query.isEmpty ? store.logLines : store.logLines.filter { $0.localizedCaseInsensitiveContains(query) }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading) {
                    Text(resource.name).font(.headline)
                    Text("\(resource.namespace ?? "") · live pod logs").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                if containers.count > 1 {
                    Picker("Container", selection: $selectedContainer) { ForEach(containers, id: \.self) { Text($0).tag($0) } }.frame(maxWidth: 160)
                }
                Menu {
                    Picker("Recent lines", selection: $tailLines) {
                        Text("100 lines").tag(100)
                        Text("500 lines").tag(500)
                        Text("2,000 lines").tag(2_000)
                        Text("5,000 lines").tag(5_000)
                        Text("10,000 lines").tag(10_000)
                    }
                } label: {
                    Label("\(tailLines) lines", systemImage: "text.line.first.and.arrowtriangle.forward")
                }
                Menu {
                    Picker("Start time", selection: $sinceSeconds) {
                        Text("Any available time").tag(Optional<Int>.none)
                        Text("Last 5 minutes").tag(Optional(5 * 60))
                        Text("Last 15 minutes").tag(Optional(15 * 60))
                        Text("Last hour").tag(Optional(60 * 60))
                        Text("Last 6 hours").tag(Optional(6 * 60 * 60))
                        Text("Last day").tag(Optional(24 * 60 * 60))
                    }
                } label: {
                    Label(sinceLabel, systemImage: "clock.arrow.circlepath")
                }
                Toggle("Previous", isOn: $previous).toggleStyle(.switch)
                Toggle("Timestamps", isOn: $timestamps).toggleStyle(.switch)
                Toggle("Follow", isOn: $isFollowing).toggleStyle(.switch)
                Button("Reload") { reload() }
                Toggle("Wrap", isOn: $wrapsLines).toggleStyle(.switch)
                Button("Copy") { copyVisibleLines() }.disabled(visibleLines.isEmpty)
                Button("Save…") { saveVisibleLines() }.disabled(visibleLines.isEmpty)
                Button("Close") { dismiss() }
            }
            .padding()
            Divider()
            TextField("Filter log lines", text: $filter)
                .textFieldStyle(.roundedBorder)
                .padding(.horizontal)
                .padding(.vertical, 8)
            if store.droppedLogLineCount > 0 {
                Text("K9k kept the newest 10,000 streamed lines; \(store.droppedLogLineCount) earlier line\(store.droppedLogLineCount == 1 ? "" : "s") were discarded from this view.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal)
                    .padding(.bottom, 6)
            }
            ScrollViewReader { proxy in
                ScrollView([.vertical, .horizontal]) {
                    LazyVStack(alignment: .leading, spacing: 2) {
                        ForEach(Array(visibleLines.enumerated()), id: \.offset) { offset, line in
                            Text(line)
                                .font(.system(.caption, design: .monospaced))
                                .textSelection(.enabled)
                                .lineLimit(wrapsLines ? nil : 1)
                                .fixedSize(horizontal: !wrapsLines, vertical: true)
                                .frame(maxWidth: wrapsLines ? .infinity : nil, alignment: .leading)
                                .id(offset)
                        }
                    }
                    .padding()
                }
                .onChange(of: visibleLines.count) { _, count in if isFollowing, count > 0 { withAnimation(.linear(duration: 0.1)) { proxy.scrollTo(count - 1, anchor: .bottom) } } }
            }
        }
        .frame(minWidth: 760, minHeight: 440)
        .task { selectedContainer = containers.first ?? ""; await store.openLogs(for: resource, container: selectedContainer, previous: previous, timestamps: timestamps, follow: isFollowing, tailLines: tailLines, sinceSeconds: sinceSeconds) }
        .onDisappear { Task { await store.closeLogs() } }
    }

    private var sinceLabel: String {
        switch sinceSeconds {
        case .none: "Any time"
        case .some(300): "Last 5m"
        case .some(900): "Last 15m"
        case .some(3_600): "Last hour"
        case .some(21_600): "Last 6h"
        case .some(86_400): "Last day"
        default: "Recent"
        }
    }

    private func reload() {
        Task {
            await store.openLogs(
                for: resource, container: selectedContainer, previous: previous,
                timestamps: timestamps, follow: isFollowing, tailLines: tailLines,
                sinceSeconds: sinceSeconds
            )
        }
    }

    private func copyVisibleLines() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(visibleLines.joined(separator: "\n"), forType: .string)
    }

    private func saveVisibleLines() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "\(resource.name)-logs.txt"
        panel.allowedContentTypes = [.plainText]
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            guard let data = visibleLines.joined(separator: "\n").data(using: .utf8) else {
                store.errorMessage = "K9k could not encode the visible log lines."
                return
            }
            try data.write(to: url, options: .atomic)
        } catch {
            store.errorMessage = "K9k could not save logs: \(error.localizedDescription)"
        }
    }
}
