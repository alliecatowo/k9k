import AppKit
import SwiftUI

struct LogStreamView: View {
    @Environment(ClusterStore.self) private var store
    let resource: ResourceSummary
    @Environment(\.dismiss) private var dismiss
    @State private var isFollowing = true
    @State private var selectedContainerID = ""
    @State private var previous = false
    @State private var timestamps = true
    @State private var tailLines = 500
    @State private var sinceSeconds: Int?
    @State private var filter = ""
    @State private var wrapsLines = false
    @State private var hasStarted = false
    @State private var pendingLineCount = 0

    private var containers: [LogContainerChoice] {
        let spec = resource.raw?.objectValue?["spec"]?.objectValue ?? [:]
        return LogContainerChoice.choices(in: spec)
    }

    private var selectedContainer: LogContainerChoice? {
        containers.first { $0.id == selectedContainerID }
    }
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
                    Picker("Container", selection: $selectedContainerID) {
                        ForEach(containers) { container in
                            Text(container.title).tag(container.id)
                        }
                    }
                    .frame(maxWidth: 180)
                    .accessibilityLabel("Pod container")
                    .accessibilityHint("Switches between app, init, and ephemeral container logs")
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
                Toggle("Previous", isOn: $previous)
                    .toggleStyle(.switch)
                    .disabled(selectedContainer?.supportsPrevious == false)
                    .help(selectedContainer?.supportsPrevious == false ? "Kubernetes previous logs are only available for regular containers." : "Show logs from the previous container instance")
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
                ZStack(alignment: .bottomTrailing) {
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
                    if pendingLineCount > 0 {
                        Button {
                            isFollowing = true
                            pendingLineCount = 0
                            scrollToLatest(with: proxy)
                        } label: {
                            Label("Jump to latest (\(pendingLineCount))", systemImage: "arrow.down.to.line.compact")
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                        .padding(16)
                        .accessibilityLabel("Jump to latest log output")
                        .accessibilityHint("Resumes following \(pendingLineCount) new log line\(pendingLineCount == 1 ? "" : "s")")
                    }
                }
                .onChange(of: store.logLines.count) { previousCount, count in
                    guard count > previousCount else { return }
                    if isFollowing {
                        pendingLineCount = 0
                        scrollToLatest(with: proxy)
                    } else {
                        pendingLineCount += count - previousCount
                    }
                }
                .onChange(of: isFollowing) { _, following in
                    guard following else { return }
                    pendingLineCount = 0
                    scrollToLatest(with: proxy)
                }
            }
        }
        .frame(minWidth: 760, minHeight: 440)
        .task {
            selectedContainerID = containers.first?.id ?? ""
            hasStarted = true
            await openSelectedLogs()
        }
        .onChange(of: selectedContainerID) { previousID, _ in
            if selectedContainer?.supportsPrevious == false { previous = false }
            // The initial selection is established by the task above; do not
            // immediately cancel and reopen that first stream.
            guard hasStarted, !previousID.isEmpty else { return }
            reload()
        }
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
        pendingLineCount = 0
        Task {
            await openSelectedLogs()
        }
    }

    private func scrollToLatest(with proxy: ScrollViewProxy) {
        guard !visibleLines.isEmpty else { return }
        withAnimation(.linear(duration: 0.1)) {
            proxy.scrollTo(visibleLines.count - 1, anchor: .bottom)
        }
    }

    private func openSelectedLogs() async {
        await store.openLogs(
            for: resource,
            container: selectedContainer?.name ?? "",
            previous: previous,
            timestamps: timestamps,
            follow: isFollowing,
            tailLines: tailLines,
            sinceSeconds: sinceSeconds
        )
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

private struct LogContainerChoice: Identifiable {
    enum Kind: String {
        case app
        case initContainer
        case ephemeral

        var label: String {
            switch self {
            case .app: "App"
            case .initContainer: "Init"
            case .ephemeral: "Ephemeral"
            }
        }
    }

    let name: String
    let kind: Kind

    var id: String { "\(kind.rawValue):\(name)" }
    var title: String { kind == .app ? name : "\(kind.label) · \(name)" }
    var supportsPrevious: Bool { kind == .app }

    static func choices(in spec: [String: JSONValue]) -> [LogContainerChoice] {
        func choices(_ key: String, kind: Kind) -> [LogContainerChoice] {
            (spec[key]?.arrayValue ?? []).compactMap { value in
                guard let name = value.objectValue?["name"]?.stringValue, !name.isEmpty else { return nil }
                return LogContainerChoice(name: name, kind: kind)
            }
        }
        return choices("containers", kind: .app) +
            choices("initContainers", kind: .initContainer) +
            choices("ephemeralContainers", kind: .ephemeral)
    }
}
