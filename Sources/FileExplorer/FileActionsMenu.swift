import SwiftUI
import AppKit
import FileExplorerCore

/// Context-menu actions for a set of selected URLs in a pane. Used by both
/// the table (contextMenu forSelectionType) and the grid.
@MainActor
struct FileActions {
    let pane: PaneState
    let otherPane: PaneState?
    let renameModel: RenameSheetModel
    let batchRenameModel: BatchRenameModel

    @ViewBuilder
    func menu(for urls: Set<URL>) -> some View {
        let targets = Array(urls)
        Button("Open") {
            for url in targets { NSWorkspace.shared.open(url) }
        }
        .disabled(targets.isEmpty)
        Button("Reveal in Finder") {
            NSWorkspace.shared.activateFileViewerSelecting(targets)
        }
        .disabled(targets.isEmpty)
        Divider()
        Button("Rename…") {
            if let url = targets.first { renameModel.present(for: url) }
        }
        .disabled(targets.count != 1)
        Button("Batch Rename…") {
            batchRenameModel.present(
                targets: targets.sorted { $0.lastPathComponent < $1.lastPathComponent },
                existingNames: Set(pane.entries.map(\.name)))
        }
        .disabled(targets.count < 2)
        Button("New Folder") {
            Task { await pane.createNewFolder() }
        }
        if let otherPane {
            Divider()
            Button("Move to Other Pane") {
                Task { await pane.moveSelected(targets, into: otherPane.currentURL) }
            }
            .disabled(targets.isEmpty)
            Button("Copy to Other Pane") {
                Task { await pane.copySelected(targets, into: otherPane.currentURL) }
            }
            .disabled(targets.isEmpty)
        }
        Divider()
        Menu("Convert Image To") {
            Button("JPG") { Task { await pane.convertSelected(targets, to: .jpeg) } }
            Button("PNG") { Task { await pane.convertSelected(targets, to: .png) } }
        }
        .disabled(targets.isEmpty)
        Button("Compress") {
            Task { await pane.compressSelected(targets) }
        }
        .disabled(targets.isEmpty)
        Button("Calculate Size") {
            Task { await pane.calculateFolderSizes(targets) }
        }
        .disabled(targets.isEmpty)
        Divider()
        Button("Move to Trash") {
            Task { await pane.trashSelected(targets) }
        }
        .disabled(targets.isEmpty)
    }
}
