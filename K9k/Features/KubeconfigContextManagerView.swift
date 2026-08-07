import SwiftUI

/// Graphical context management deliberately works at the context-reference
/// layer only. It never reads or writes cluster endpoints, certificate data, or
/// user credentials from kubeconfig.
struct KubeconfigContextManagerView: View {
    @Environment(ClusterStore.self) private var store
    @Binding var isPresented: Bool
    @State private var selectedContextID: KubeContext.ID?
    @State private var renamedContext = ""
    @State private var confirmRename = false
    @State private var confirmDelete = false
    @State private var isWorking = false

    private var selectedContext: KubeContext? {
        store.contexts.first(where: { $0.id == selectedContextID })
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Kubeconfig Contexts").font(.headline)
                    Text("Rename or remove saved context references without exposing credentials.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("Close") { isPresented = false }
            }
            .padding()
            Divider()

            HSplitView {
                List(store.contexts, selection: $selectedContextID) { context in
                    VStack(alignment: .leading, spacing: 2) {
                        HStack {
                            Text(context.name).fontWeight(context.active ? .semibold : .regular)
                            if context.active { Text("Active").font(.caption).foregroundStyle(.green) }
                        }
                        Text("Cluster: \(context.cluster) · User: \(context.user)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .tag(context.id)
                }
                .frame(minWidth: 270, idealWidth: 320)

                Group {
                    if let context = selectedContext {
                        Form {
                            Section("Context") {
                                LabeledContent("Cluster", value: context.cluster)
                                LabeledContent("User", value: context.user)
                                LabeledContent("Default namespace", value: context.namespace?.isEmpty == false ? context.namespace! : "Kubernetes default")
                            }
                            Section("Rename") {
                                TextField("Context name", text: $renamedContext)
                                Button("Rename…") { confirmRename = true }
                                    .disabled(isWorking || renamedContext.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || renamedContext == context.name || store.isReadOnly)
                            }
                            Section("Remove") {
                                Button("Delete Inactive Context…", role: .destructive) { confirmDelete = true }
                                    .disabled(isWorking || context.active || store.isReadOnly)
                                if context.active {
                                    Text("Select another context before this one can be removed.")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                        .formStyle(.grouped)
                    } else {
                        ContentUnavailableView("No Context Selected", systemImage: "server.rack", description: Text("Choose a kubeconfig context to manage its saved reference."))
                    }
                }
                .frame(minWidth: 380)
            }
        }
        .frame(minWidth: 740, minHeight: 500)
        .onAppear { selectInitialContext() }
        .onChange(of: selectedContextID) { _, _ in renamedContext = selectedContext?.name ?? "" }
        .confirmationDialog("Rename kubeconfig context?", isPresented: $confirmRename, titleVisibility: .visible) {
            Button("Rename") { rename() }
        } message: {
            Text("K9k will rename only the context reference in kubeconfig. Cluster endpoints and credentials are unchanged.")
        }
        .confirmationDialog("Delete kubeconfig context?", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("Delete Context", role: .destructive) { delete() }
        } message: {
            Text("K9k will remove this inactive context reference from kubeconfig. It will not remove its cluster or user credentials.")
        }
    }

    private func selectInitialContext() {
        selectedContextID = store.selectedContext?.id ?? store.contexts.first?.id
        renamedContext = selectedContext?.name ?? ""
    }

    private func rename() {
        guard let context = selectedContext else { return }
        isWorking = true
        Task {
            defer { isWorking = false }
            if await store.renameKubeContext(context, to: renamedContext) {
                selectedContextID = renamedContext.trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }
    }

    private func delete() {
        guard let context = selectedContext else { return }
        isWorking = true
        Task {
            defer { isWorking = false }
            if await store.deleteKubeContext(context) {
                selectedContextID = store.selectedContext?.id ?? store.contexts.first?.id
            }
        }
    }
}
