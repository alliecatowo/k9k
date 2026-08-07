import SwiftUI

/// A native front end for Kubernetes list selectors. Both strings are sent to
/// the API server unchanged so Kubernetes remains the syntax authority; this
/// view deliberately does not attempt to emulate kubectl's selector parser.
struct ResourceSelectorsView: View {
    @Environment(ClusterStore.self) private var store
    @Binding var isPresented: Bool
    @State private var labelSelector = ""
    @State private var fieldSelector = ""

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section("Current resource") {
                    LabeledContent("Type", value: store.selectedResourceType?.kind ?? "No resource selected")
                    LabeledContent("Namespace", value: store.selectedNamespace)
                }
                Section("Kubernetes selectors") {
                    TextField("app.kubernetes.io/name=api", text: $labelSelector, prompt: Text("Label selector"))
                        .textFieldStyle(.roundedBorder)
                    TextField("status.phase=Running", text: $fieldSelector, prompt: Text("Field selector"))
                        .textFieldStyle(.roundedBorder)
                    Text("Selectors narrow both the initial list and the live watch. Kubernetes validates their syntax and reports any unsupported field.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .formStyle(.grouped)
            Divider()
            HStack {
                Button("Clear") {
                    labelSelector = ""
                    fieldSelector = ""
                }
                Spacer()
                Button("Cancel") { isPresented = false }
                Button("Apply") { apply() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(store.selectedResourceType == nil)
            }
            .padding()
        }
        .frame(width: 540)
        .onAppear {
            labelSelector = store.labelSelector
            fieldSelector = store.fieldSelector
        }
    }

    private func apply() {
        store.labelSelector = labelSelector.trimmingCharacters(in: .whitespacesAndNewlines)
        store.fieldSelector = fieldSelector.trimmingCharacters(in: .whitespacesAndNewlines)
        store.pinSelectorsToCurrentResource()
        isPresented = false
        Task { await store.loadResources() }
    }
}
