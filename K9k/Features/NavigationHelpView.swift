import SwiftUI

/// A native, searchable-in-context substitute for K9s' terminal help page.
/// It documents actual macOS commands, not terminal key emulation, and keeps
/// the operator's recent resource-list navigation one click away.
struct NavigationHelpView: View {
    @Environment(ClusterStore.self) private var store
    @Binding var isPresented: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline) {
                Label("Navigation & Commands", systemImage: "questionmark.circle")
                    .font(.title2.weight(.semibold))
                Spacer()
                Button("Done") { isPresented = false }
                    .keyboardShortcut(.cancelAction)
            }
            .padding([.top, .horizontal])

            Form {
                Section("Quick navigation") {
                    helpRow("Open Command Palette", shortcut: "⌘K", detail: "Search every Kubernetes resource, configured K9s alias, and native navigation command.")
                    helpRow("Go Back", shortcut: "⌘[", detail: "Return to the prior resource list in this Kubernetes context.")
                    helpRow("Go Forward", shortcut: "⌘]", detail: "Move forward after using Back.")
                    helpRow("Refresh", shortcut: "Toolbar", detail: "Relist the current GVR and restart its bounded watch.")
                    helpRow("Toggle Inspector", shortcut: "Toolbar", detail: "Show or hide JSON, events, metrics, and resource actions.")
                }

                Section("Kubernetes workflows") {
                    helpRow("Filter Resources", shortcut: "Toolbar", detail: "Apply label and field selectors to the list and its live watch.")
                    helpRow("Resource Actions", shortcut: "Toolbar", detail: "Open logs, terminal, port forward, manifest, access check, Pulse, and workload actions for the current selection.")
                    helpRow("Read-only Mode", shortcut: "Actions / Settings", detail: "Disables native mutation controls. Kubernetes authorization is still checked for every protected operation.")
                    helpRow("Settings", shortcut: "K9k menu", detail: "Manage context references, namespace defaults, favourites, and compatible K9s configuration files.")
                }

                Section("Recent resource lists") {
                    if store.recentResourceNavigation.isEmpty {
                        ContentUnavailableView("No Recent Navigation", systemImage: "clock.arrow.circlepath", description: Text("Resource lists you open in this Kubernetes context appear here."))
                    } else {
                        ForEach(Array(store.recentResourceNavigation.prefix(10))) { entry in
                            Button {
                                Task {
                                    await store.openRecentNavigation(entry)
                                    isPresented = false
                                }
                            } label: {
                                HStack {
                                    Image(systemName: "clock.arrow.circlepath")
                                        .foregroundStyle(.secondary)
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(entry.title)
                                        Text(entry.detail).font(.caption).foregroundStyle(.secondary)
                                    }
                                    Spacer()
                                }
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel("Open recent \(entry.title), \(entry.detail)")
                        }
                    }
                }

                Section {
                    Text("History is stored locally as resource identity and list scope only. It never stores Kubernetes object data, kubeconfig credentials, or cluster endpoints, and it never switches contexts automatically.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .formStyle(.grouped)
        }
        .frame(width: 620, height: 650)
    }

    @ViewBuilder
    private func helpRow(_ title: String, shortcut: String, detail: String) -> some View {
        LabeledContent {
            Text(shortcut)
                .font(.body.monospaced())
                .foregroundStyle(.secondary)
        } label: {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }
}
