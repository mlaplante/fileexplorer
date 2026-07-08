import Foundation

/// Registers inverse file operations on an UndoManager. All closures hop back
/// to the MainActor and re-drive PaneState so undo also reloads/refreshes.
@MainActor
public enum UndoRecorder {
    public static func recordMove(_ moves: [(from: URL, to: URL)],
                                  actionName: String = "Move",
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
                //
                // Restore to the EXACT recorded path (not `move`, which
                // would re-derive the target from `move.to`'s current
                // basename — wrong for same-directory renames, where that
                // resolves back to the file's own current path).
                //
                // All pairs are restored via ONE relocate() call so a
                // swapped/cycled set of names (e.g. a batch-rename handoff)
                // stages every item through a temp name first — restoring
                // pair-by-pair would collide when a restore target is
                // currently occupied by another item in the same batch.
                // relocate's outcome.pairs are already (from: move.to,
                // to: move.from) — exactly the shape recordMove needs to
                // re-register the redo (move it back from move.from to
                // move.to when redo fires).
                let outcome = RenameExecutor.relocate(
                    moves.map { (from: $0.to, to: $0.from) })
                if !outcome.pairs.isEmpty {
                    UndoRecorder.recordMove(
                        outcome.pairs,
                        actionName: actionName,
                        on: undoManager, pane: pane)
                }
                if !outcome.failures.isEmpty {
                    pane.reportOpFailure(Self.aggregate(outcome.failures))
                }
                Task { await pane.reload() }
            }
        }
        undoManager.setActionName(actionName)
    }

    public static func recordTrash(_ trashes: [(original: URL, trashed: URL)],
                                   actionName: String = "Move to Trash",
                                   on undoManager: UndoManager,
                                   pane: PaneState) {
        guard !trashes.isEmpty else { return }
        undoManager.registerUndo(withTarget: pane) { pane in
            MainActor.assumeIsolated {
                // Same reasoning as recordMove: perform the restore and
                // re-register synchronously so redo lands on the redo
                // stack; only the reload is deferred. Restore to the EXACT
                // original path — macOS renames items that collide with an
                // existing name on entry to .Trash, so `item.trashed`'s
                // current basename is not necessarily `item.original`'s.
                var restored: [URL] = []
                var failures: [String] = []
                for item in trashes {
                    switch FileOperationService.relocate(item.trashed, toExactly: item.original) {
                    case .success:
                        restored.append(item.original)
                    case .failure(let error):
                        failures.append(error.message)
                    }
                }
                // Redo of a restore = trash again, under the same action
                // name this trash was originally recorded under (so e.g.
                // undoing "New Folder" and redoing shows "Redo New Folder",
                // not "Redo Move to Trash").
                UndoRecorder.recordCreation(restored,
                                            actionName: actionName,
                                            on: undoManager, pane: pane)
                if !failures.isEmpty {
                    pane.reportOpFailure(Self.aggregate(failures))
                }
                Task { await pane.reload() }
            }
        }
        undoManager.setActionName(actionName)
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
                let failures = results.compactMap { result -> String? in
                    if case .failure(let error) = result.outcome { return error.message }
                    return nil
                }
                UndoRecorder.recordTrash(
                    trashed.map { (original: $0.0, trashed: $0.1) },
                    actionName: actionName,
                    on: undoManager, pane: pane)
                if !failures.isEmpty {
                    pane.reportOpFailure(Self.aggregate(failures))
                }
                Task { await pane.reload() }
            }
        }
        undoManager.setActionName(actionName)
    }

    private static func aggregate(_ failures: [String]) -> String {
        let first = failures[0]
        let suffix = failures.count > 1 ? " (+\(failures.count - 1) more)" : ""
        return "Undo failed for \(failures.count) item\(failures.count == 1 ? "" : "s"): \(first)\(suffix)"
    }
}
