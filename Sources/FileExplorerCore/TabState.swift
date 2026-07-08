import Foundation
import Observation

/// One browser tab: one or two panes plus which of them is active.
@MainActor
@Observable
public final class TabState: Identifiable {
    public let id = UUID()
    public private(set) var panes: [PaneState]
    public var activePaneIndex = 0
    private let onNavigated: (@MainActor (URL) -> Void)?

    public init(url: URL, onNavigated: (@MainActor (URL) -> Void)? = nil) {
        self.onNavigated = onNavigated
        let pane = PaneState(url: url)
        pane.onNavigated = onNavigated
        panes = [pane]
    }

    /// Restore from a saved snapshot; empty/oversized pane lists and
    /// out-of-range indices are clamped rather than trusted.
    public init(snapshot: SessionSnapshot.Tab, fallback: URL,
                onNavigated: (@MainActor (URL) -> Void)? = nil) {
        self.onNavigated = onNavigated
        let paneSnapshots = snapshot.panes.isEmpty
            ? [SessionSnapshot.Pane(path: fallback.path)]
            : Array(snapshot.panes.prefix(2))
        panes = paneSnapshots.map { paneSnapshot in
            let pane = PaneState(snapshot: paneSnapshot, fallback: fallback)
            pane.onNavigated = onNavigated
            return pane
        }
        activePaneIndex = max(0, min(snapshot.activePaneIndex, panes.count - 1))
    }

    public var isDual: Bool { panes.count == 2 }

    public var activePane: PaneState {
        panes[min(activePaneIndex, panes.count - 1)]
    }

    /// Tab-chip label: the active pane's folder name.
    public var title: String {
        let name = activePane.currentURL.lastPathComponent
        return name.isEmpty ? "/" : name
    }

    public func snapshot() -> SessionSnapshot.Tab {
        SessionSnapshot.Tab(panes: panes.map { $0.snapshot() },
                            activePaneIndex: activePaneIndex)
    }

    public func toggleDual() {
        if isDual {
            activePaneIndex = 0
            panes.removeLast()   // PaneState deinit stops its watcher
        } else {
            let pane = PaneState(url: activePane.currentURL)
            pane.onNavigated = onNavigated
            panes.append(pane)
            activePaneIndex = 1
        }
    }

    /// Folder-compare mode (dual pane only). Set by runCompare(), cleared
    /// by endCompare() and whenever either pane navigates away from the
    /// compared roots (checked by the UI layer before badging).
    public private(set) var compareResult: FolderComparator.Result?
    /// Roots the comparison was computed against — badges must not apply
    /// after either pane navigates elsewhere.
    public private(set) var compareLeftRoot: URL?
    public private(set) var compareRightRoot: URL?
    public private(set) var isComparing = false

    /// Gathers both listings off-main and classifies. No-op unless dual.
    public func runCompare() async {
        guard panes.count == 2 else { return }
        let leftRoot = panes[0].currentURL
        let rightRoot = panes[1].currentURL
        let includeHidden = panes[0].showHidden
        isComparing = true
        let result = await Task.detached(priority: .userInitiated) {
            let left = FolderComparator.listing(root: leftRoot,
                                                includeHidden: includeHidden)
            let right = FolderComparator.listing(root: rightRoot,
                                                 includeHidden: includeHidden)
            return FolderComparator.compare(left: left, right: right)
        }.value
        compareResult = result
        compareLeftRoot = leftRoot.standardizedFileURL
        compareRightRoot = rightRoot.standardizedFileURL
        isComparing = false
    }

    public func endCompare() {
        compareResult = nil
        compareLeftRoot = nil
        compareRightRoot = nil
        isComparing = false
    }

    /// One-way sync per the compare result. ONE undo step: the target
    /// pane's UndoManager groups the creation-undo and the trash-restore.
    public func syncCompare(direction: FolderComparator.Direction) async {
        guard let result = compareResult, panes.count == 2 else { return }
        let sourcePane = direction == .leftToRight ? panes[0] : panes[1]
        let targetPane = direction == .leftToRight ? panes[1] : panes[0]
        let sourceRoot = sourcePane.currentURL
        let targetRoot = targetPane.currentURL
        let plan = FolderComparator.syncPlan(result: result, direction: direction)
        guard !plan.isEmpty else { return }
        let outcome = await Task.detached(priority: .userInitiated) {
            SyncExecutor.execute(plan, from: sourceRoot, to: targetRoot)
        }.value
        if let undoManager = targetPane.undoManager,
           !outcome.copied.isEmpty || !outcome.trashed.isEmpty {
            // ORDER IS LOAD-BEARING: grouped registrations fire LIFO on undo.
            // recordTrash must be registered FIRST so that on undo the
            // creation-undo (registered second, fires first) trashes the new
            // copies and VACATES the overwrite paths before the trash-restore
            // relocates the old files back — relocate() fails loudly on an
            // occupied path, so the reverse order strands both versions in
            // the Trash. Redo re-registers inside the undo pass and flips
            // LIFO again: restored-old is trashed first, then the new copies
            // relocate back. One visible step each way.
            // (No setActionName after endUndoGrouping: it requires an OPEN
            // group — an implicit one exists under event grouping, but none
            // under manual grouping (tests), where it raises. The recorders
            // already set "Sync Folders" inside the group.)
            undoManager.beginUndoGrouping()
            UndoRecorder.recordTrash(outcome.trashed, actionName: "Sync Folders",
                                     on: undoManager, pane: targetPane)
            UndoRecorder.recordCreation(outcome.copied, actionName: "Sync Folders",
                                        on: undoManager, pane: targetPane)
            undoManager.endUndoGrouping()
        }
        await targetPane.reload()
        if !outcome.failures.isEmpty {
            targetPane.reportTagFailure(
                outcome.failures.prefix(3).joined(separator: " ")
                + (outcome.failures.count > 3
                   ? " (+\(outcome.failures.count - 3) more)" : ""))
        }
        // Refresh the comparison against the new on-disk state.
        await runCompare()
    }
}
