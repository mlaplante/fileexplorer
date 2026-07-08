import SwiftUI
import FileExplorerCore

/// Confirmation model + sheet for a one-way folder sync: shows exactly the
/// planned operations before anything touches disk.
@MainActor
@Observable
final class SyncPreviewModel {
    var operations: [FolderComparator.SyncOperation] = []
    var direction: FolderComparator.Direction = .leftToRight
    @ObservationIgnored weak var tab: TabState?

    var isPresented: Bool { !operations.isEmpty }

    func present(direction: FolderComparator.Direction, tab: TabState) {
        guard let result = tab.compareResult else { return }
        self.direction = direction
        self.tab = tab
        operations = FolderComparator.syncPlan(result: result, direction: direction)
    }

    func dismiss() {
        operations = []
        tab = nil
    }
}

struct SyncPreviewSheet: View {
    @Bindable var model: SyncPreviewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(model.direction == .leftToRight
                 ? "Sync \(model.operations.count) Items → Right Pane"
                 : "Sync \(model.operations.count) Items → Left Pane")
                .font(.headline)
            ScrollView {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(model.operations, id: \.relativePath) { operation in
                        HStack {
                            Image(systemName: operation.kind == .overwrite
                                  ? "exclamationmark.triangle" : "plus.circle")
                                .foregroundStyle(operation.kind == .overwrite
                                                 ? .orange : .green)
                            Text(operation.relativePath)
                            Spacer()
                            Text(operation.kind == .overwrite ? "overwrite" : "copy")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        .font(.callout)
                    }
                }
            }
            .frame(maxHeight: 260)
            Text("Overwritten files are moved to the Trash first; the whole sync is one Undo step.")
                .font(.caption)
                .foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button("Cancel") { model.dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Sync") {
                    let direction = model.direction
                    let tab = model.tab
                    model.dismiss()
                    Task { await tab?.syncCompare(direction: direction) }
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 520)
    }
}
