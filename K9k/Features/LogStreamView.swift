import SwiftUI

struct LogStreamView: View {
    @Environment(ClusterStore.self) private var store
    let resource: ResourceSummary
    @Environment(\.dismiss) private var dismiss
    @State private var isFollowing = true
    @State private var selectedContainer = ""
    @State private var previous = false
    @State private var timestamps = true

    private var containers: [String] { resource.raw?.objectValue?["spec"]?.objectValue?["containers"]?.arrayValue?.compactMap { $0.objectValue?["name"]?.stringValue } ?? [] }

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
                Toggle("Previous", isOn: $previous).toggleStyle(.switch)
                Toggle("Timestamps", isOn: $timestamps).toggleStyle(.switch)
                Toggle("Follow", isOn: $isFollowing).toggleStyle(.switch)
                Button("Reload") { Task { await store.openLogs(for: resource, container: selectedContainer, previous: previous, timestamps: timestamps) } }
                Button("Close") { dismiss() }
            }
            .padding()
            Divider()
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 2) {
                        ForEach(Array(store.logLines.enumerated()), id: \.offset) { offset, line in
                            Text(line).font(.system(.caption, design: .monospaced)).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading).id(offset)
                        }
                    }
                    .padding()
                }
                .onChange(of: store.logLines.count) { _, count in if isFollowing, count > 0 { withAnimation(.linear(duration: 0.1)) { proxy.scrollTo(count - 1, anchor: .bottom) } } }
            }
        }
        .frame(minWidth: 760, minHeight: 440)
        .task { selectedContainer = containers.first ?? ""; await store.openLogs(for: resource, container: selectedContainer, previous: previous, timestamps: timestamps) }
        .onDisappear { Task { await store.closeLogs() } }
    }
}
