import SwiftUI

/// Graphical context management deliberately works at the context-reference
/// layer only. It never reads or writes cluster endpoints, certificate data, or
/// user credentials from kubeconfig.
struct KubeconfigContextManagerView: View {
    @Environment(ClusterStore.self) private var store
    @Binding var isPresented: Bool
    @State private var selectedContextID: KubeContext.ID?
    @State private var renamedContext = ""
    @State private var copiedContextName = ""
    @State private var copiedContextNamespace = ""
    @State private var confirmRename = false
    @State private var confirmCopy = false
    @State private var confirmDelete = false
    @State private var isWorking = false
    @State private var inspection: KubeconfigContextInspection?
    @State private var isInspecting = false

    private var selectedContext: KubeContext? {
        store.contexts.first(where: { $0.id == selectedContextID })
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Kubeconfig Contexts").font(.headline)
                    Text("Duplicate, rename, or remove saved context references without exposing credentials.")
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
                            Section("Reference relationships") {
                                KubeconfigReferenceGraph(inspection: inspection, isLoading: isInspecting) {
                                    refreshInspection()
                                }
                            }
                            Section("Rename") {
                                TextField("Context name", text: $renamedContext)
                                Button("Rename…") { confirmRename = true }
                                    .disabled(isWorking || renamedContext.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || renamedContext == context.name || store.isReadOnly)
                            }
                            Section("Duplicate") {
                                TextField("New context name", text: $copiedContextName)
                                Picker("Default namespace", selection: $copiedContextNamespace) {
                                    Text("Kubernetes default").tag("")
                                    ForEach(store.namespaces.filter { $0 != "All Namespaces" }, id: \.self) { Text($0).tag($0) }
                                }
                                Button("Duplicate Context…") { confirmCopy = true }
                                    .disabled(isWorking || copiedContextName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || copiedContextName.trimmingCharacters(in: .whitespacesAndNewlines) == context.name || store.contexts.contains(where: { $0.name == copiedContextName.trimmingCharacters(in: .whitespacesAndNewlines) }) || store.isReadOnly)
                                Text("The new context keeps this context's cluster and user references. Credentials and endpoint settings are not displayed or changed.")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
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
        .onChange(of: selectedContextID) { _, _ in
            renamedContext = selectedContext?.name ?? ""
            copiedContextName = ""
            copiedContextNamespace = selectedContext?.namespace ?? ""
            inspection = nil
        }
        .task(id: selectedContextID) { refreshInspection() }
        .confirmationDialog("Rename kubeconfig context?", isPresented: $confirmRename, titleVisibility: .visible) {
            Button("Rename") { rename() }
        } message: {
            Text("K9k will rename only the context reference in kubeconfig. Cluster endpoints and credentials are unchanged.")
        }
        .confirmationDialog("Duplicate kubeconfig context?", isPresented: $confirmCopy, titleVisibility: .visible) {
            Button("Duplicate Context") { copy() }
        } message: {
            Text("K9k will create \(copiedContextName.trimmingCharacters(in: .whitespacesAndNewlines)) using \(selectedContext?.name ?? "the selected context")'s saved cluster and user references. Credentials and endpoint settings are unchanged.")
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
        copiedContextNamespace = selectedContext?.namespace ?? ""
    }

    private func refreshInspection() {
        guard let context = selectedContext else {
            inspection = nil
            return
        }
        isInspecting = true
        Task {
            defer { isInspecting = false }
            inspection = await store.inspectKubeconfigContext(context)
        }
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

    private func copy() {
        guard let context = selectedContext else { return }
        isWorking = true
        Task {
            defer { isWorking = false }
            if let copy = await store.copyKubeContext(context, to: copiedContextName, namespace: copiedContextNamespace) {
                selectedContextID = copy.id
            }
        }
    }
}

/// A deliberately small relationship graph for one kubeconfig context. The
/// graph visualizes only names and map-key integrity; no kubeconfig value is
/// rendered here, so endpoint and credential fields stay opaque.
private struct KubeconfigReferenceGraph: View {
    let inspection: KubeconfigContextInspection?
    let isLoading: Bool
    let refresh: () -> Void

    var body: some View {
        if isLoading {
            ProgressView("Checking saved references…")
        } else if let inspection, let context = inspection.context {
            VStack(alignment: .leading, spacing: 10) {
                relationship(source: context.name, destination: inspection.cluster, label: "Cluster", symbol: "server.rack")
                relationship(source: context.name, destination: inspection.authInfo, label: "User", symbol: "person.crop.circle")

                if inspection.diagnostics.isEmpty {
                    Label("All saved references resolve.", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                        .accessibilityLabel("All saved kubeconfig references resolve")
                } else {
                    ForEach(inspection.diagnostics) { diagnostic in
                        Label(diagnostic.message, systemImage: diagnostic.symbolName)
                            .foregroundStyle(diagnostic.severity == "error" ? .red : .orange)
                    }
                }

                Button("Recheck References", action: refresh)
                    .help("Read kubeconfig relationship names again without displaying credentials or endpoints")
                Text("Only context, cluster, and user reference names are shown. Servers, certificates, tokens, and authentication settings stay in kubeconfig.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        } else {
            VStack(alignment: .leading, spacing: 8) {
                Label("Reference details are unavailable.", systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.secondary)
                Button("Recheck References", action: refresh)
            }
        }
    }

    @ViewBuilder
    private func relationship(source: String, destination: KubeconfigReference, label: String, symbol: String) -> some View {
        HStack(spacing: 8) {
            Label(source, systemImage: "circle")
                .lineLimit(1)
            Image(systemName: "arrow.right")
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            Label(destination.name.isEmpty ? "No \(label.lowercased()) reference" : destination.name, systemImage: symbol)
                .lineLimit(1)
            Spacer(minLength: 0)
            Label(destination.exists ? "Resolved" : "Missing", systemImage: destination.exists ? "checkmark.circle" : "xmark.circle")
                .foregroundStyle(destination.exists ? .green : .red)
                .labelStyle(.titleAndIcon)
        }
        .accessibilityElement(children: .combine)
        if destination.usedBy.count > 1 {
            Text("Shared by \(destination.usedBy.joined(separator: ", "))")
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.leading, 24)
        }
    }
}
