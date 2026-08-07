import SwiftUI

struct LogStreamView: View {
    @Environment(ClusterStore.self) private var store
    let resource: ResourceSummary
    @Environment(\.dismiss) private var dismiss
    @State private var isFollowing = true

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading) {
                    Text(resource.name).font(.headline)
                    Text("\(resource.namespace ?? "") · live pod logs").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Toggle("Follow", isOn: $isFollowing).toggleStyle(.switch)
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
        .task { await store.openLogs(for: resource) }
        .onDisappear { Task { await store.closeLogs() } }
    }
}
