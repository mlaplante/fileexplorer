import SwiftUI
import FileExplorerCore

@MainActor
@Observable
final class WorkspaceProfileModel {
    var isPresented = false
    var draftName = ""

    func present(defaultName: String) {
        draftName = defaultName
        isPresented = true
    }

    func dismiss() {
        draftName = ""
        isPresented = false
    }
}

struct WorkspaceProfileSheet: View {
    @Bindable var model: WorkspaceProfileModel
    var onSave: (String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Save Workspace")
                .font(.headline)
            TextField("Name", text: $model.draftName)
                .textFieldStyle(.roundedBorder)
                .frame(width: 320)
                .onSubmit { confirm() }
            HStack {
                Spacer()
                Button("Cancel") { model.dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Save") { confirm() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(model.draftName
                        .trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(20)
    }

    private func confirm() {
        let name = model.draftName.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return }
        onSave(name)
        model.dismiss()
    }
}

