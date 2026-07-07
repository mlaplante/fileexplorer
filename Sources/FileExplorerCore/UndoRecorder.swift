import Foundation

/// Registers inverse file operations on an UndoManager. All closures hop back
/// to the MainActor and re-drive PaneState so undo also reloads/refreshes.
@MainActor
public enum UndoRecorder {
    public static func recordMove(_ moves: [(from: URL, to: URL)],
                                  on undoManager: UndoManager,
                                  pane: PaneState) {
        guard !moves.isEmpty else { return }
        undoManager.registerUndo(withTarget: pane) { pane in
            MainActor.assumeIsolated {
                // The inverse move and its re-registration must happen
                // synchronously here, while UndoManager.isUndoing/isRedoing
                // is still true — otherwise registerUndo lands on the undo
                // stack instead of the redo stack. Only the reload (which
                // doesn't affect undo/redo bookkeeping) is deferred.
                for move in moves {
                    _ = FileOperationService.move(
                        [move.to], into: move.from.deletingLastPathComponent())
                }
                UndoRecorder.recordMove(
                    moves.map { (from: $0.to, to: $0.from) },
                    on: undoManager, pane: pane)
                Task { await pane.reload() }
            }
        }
        undoManager.setActionName("Move")
    }

    public static func recordTrash(_ trashes: [(original: URL, trashed: URL)],
                                   on undoManager: UndoManager,
                                   pane: PaneState) {
        guard !trashes.isEmpty else { return }
        undoManager.registerUndo(withTarget: pane) { pane in
            MainActor.assumeIsolated {
                // Same reasoning as recordMove: perform the restore and
                // re-register synchronously so redo lands on the redo
                // stack; only the reload is deferred.
                var restored: [(from: URL, to: URL)] = []
                for item in trashes {
                    let parent = item.original.deletingLastPathComponent()
                    if case .success(let back) =
                        FileOperationService.move([item.trashed], into: parent)[0].outcome {
                        restored.append((from: item.original, to: back))
                    }
                }
                // Redo of a restore = trash again.
                UndoRecorder.recordCreation(restored.map(\.to),
                                            actionName: "Move to Trash",
                                            on: undoManager, pane: pane)
                Task { await pane.reload() }
            }
        }
        undoManager.setActionName("Move to Trash")
    }

    /// Undo for created items (copies, new folders): trash them.
    public static func recordCreation(_ created: [URL],
                                      actionName: String,
                                      on undoManager: UndoManager,
                                      pane: PaneState) {
        guard !created.isEmpty else { return }
        undoManager.registerUndo(withTarget: pane) { pane in
            MainActor.assumeIsolated {
                // Same reasoning as recordMove: perform the trash and
                // re-register synchronously so redo lands on the redo
                // stack; only the reload is deferred.
                let results = FileOperationService.trash(created)
                let trashed = results.compactMap { result -> (URL, URL)? in
                    if case .success(let url) = result.outcome {
                        return (result.source, url)
                    }
                    return nil
                }
                UndoRecorder.recordTrash(
                    trashed.map { (original: $0.0, trashed: $0.1) },
                    on: undoManager, pane: pane)
                Task { await pane.reload() }
            }
        }
        undoManager.setActionName(actionName)
    }
}
