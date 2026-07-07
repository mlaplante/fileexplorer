import SwiftUI
import FileExplorerCore

/// Sheet state for single-item rename (no @State on this toolchain).
@MainActor
@Observable
final class RenameSheetModel {
    var target: URL?
    var draftName = ""

    var isPresented: Bool { target != nil }

    func present(for url: URL) {
        target = url
        draftName = url.lastPathComponent
    }

    func dismiss() {
        target = nil
        draftName = ""
    }
}

struct RenameSheet: View {
    @Bindable var model: RenameSheetModel
    var onConfirm: (URL, String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Rename")
                .font(.headline)
            TextField("Name", text: $model.draftName)
                .textFieldStyle(.roundedBorder)
                .frame(width: 320)
                .onSubmit { confirm() }
            HStack {
                Spacer()
                Button("Cancel") { model.dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Rename") { confirm() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(model.draftName.isEmpty)
            }
        }
        .padding(20)
    }

    private func confirm() {
        guard let target = model.target, !model.draftName.isEmpty else { return }
        let newName = model.draftName
        model.dismiss()
        onConfirm(target, newName)
    }
}
