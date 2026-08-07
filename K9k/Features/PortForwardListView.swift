import AppKit
import SwiftUI

struct PortForwardListView: View {
    @Environment(ClusterStore.self) private var store
    @Binding var isPresented: Bool
    @State private var benchmarkForward: ActivePortForward?

    var body: some View {
        NavigationStack {
            Group {
                if store.activePortForwards.isEmpty {
                    ContentUnavailableView("No Active Forwards", systemImage: "network", description: Text("Pod port forwards started in K9k remain available here until you stop them."))
                } else {
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 0) {
                            ForEach(store.activePortForwards) { forward in
                                VStack(alignment: .leading, spacing: 7) {
                                    Text(forward.binding.endpoint).font(.system(.body, design: .monospaced))
                                    Text("\(forward.binding.namespace) · loopback only").font(.caption).foregroundStyle(.secondary)
                                    HStack {
                                        Button("Copy") { NSPasteboard.general.clearContents(); NSPasteboard.general.setString("http://\(forward.binding.localAddress):\(forward.binding.localPort)", forType: .string) }
                                        Button("Open") { NSWorkspace.shared.open(URL(string: "http://\(forward.binding.localAddress):\(forward.binding.localPort)")!) }
                                        Button("Benchmark…") { benchmarkForward = forward }
                                        Spacer()
                                        Button("Stop", role: .destructive) { Task { await store.closePortForward(streamID: forward.streamID) } }
                                    }
                                    .accessibilityElement(children: .contain)
                                }
                                .padding(16)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                Divider()
                            }
                        }
                    }
                }
            }
            .navigationTitle("Active Port Forwards")
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Close") { isPresented = false } } }
        }
        .frame(minWidth: 580, minHeight: 360)
        .sheet(item: $benchmarkForward) { HTTPBenchmarkView(forward: $0) }
    }
}
