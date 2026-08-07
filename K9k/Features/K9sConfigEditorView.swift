import SwiftUI

struct K9sConfigEditorView: View {
    @Environment(ClusterStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    let name: String
    @State private var draft = ""
    @State private var confirmSave = false
    @State private var isSaving = false

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading) {
                    Text("Edit \(name).yaml").font(.headline)
                    Text(store.k9sConfigDocument?.path ?? "Loading K9s configuration…").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button("Close") { dismiss() }
            }.padding()
            Divider()
            SyntaxHighlightingEditor(source: $draft, language: .yaml, isEditable: !isSaving).padding(8)
            Divider()
            HStack {
                Text("Saved only after YAML compatibility validation and confirmation.").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Save…") { confirmSave = true }.disabled(store.k9sConfigDocument == nil || isSaving || draft == store.k9sConfigDocument?.content)
            }.padding()
        }
        .frame(minWidth: 760, minHeight: 540)
        .task { await store.loadK9sConfigDocument(named: name); draft = store.k9sConfigDocument?.content ?? "" }
        .confirmationDialog("Save \(name).yaml?", isPresented: $confirmSave, titleVisibility: .visible) {
            Button("Save", role: .destructive) { Task { await save() } }
        } message: { Text("K9k will validate the K9s-compatible YAML and refuse to overwrite a file changed since you opened it.") }
    }

    private func save() async {
        guard let document = store.k9sConfigDocument else { return }
        isSaving = true
        defer { isSaving = false }
        if await store.saveK9sConfigDocument(document, content: draft) { dismiss() }
    }
}
