import Foundation
import FileExplorerCore

@MainActor
func newFolderWithSelectionTests() async {
    let fm = FileManager.default

    await test("newFolderWithSelection moves selection into a new folder") {
        let dir = try makeTempDir()
        defer { try? fm.removeItem(at: dir) }
        let a = dir.appendingPathComponent("a.txt")
        let b = dir.appendingPathComponent("b.txt")
        try Data("a".utf8).write(to: a)
        try Data("b".utf8).write(to: b)

        let pane = PaneState(url: dir)
        await pane.reload()
        await pane.newFolderWithSelection([a, b])

        let folder = dir.appendingPathComponent("untitled folder")
        expect(fm.fileExists(atPath: folder.appendingPathComponent("a.txt").path),
               "a moved into new folder")
        expect(fm.fileExists(atPath: folder.appendingPathComponent("b.txt").path),
               "b moved into new folder")
        expectEqual(pane.selection, [folder.standardizedFileURL],
                    "new folder selected")
        expectEqual(pane.pendingRenameURL, folder.standardizedFileURL,
                    "rename requested for new folder")
    }

    await test("newFolderWithSelection undo and redo are one step") {
        let dir = try makeTempDir()
        defer { try? fm.removeItem(at: dir) }
        let a = dir.appendingPathComponent("a.txt")
        let b = dir.appendingPathComponent("b.txt")
        try Data().write(to: a)
        try Data().write(to: b)

        let undoManager = UndoManager()
        let pane = PaneState(url: dir)
        pane.undoManager = undoManager
        await pane.reload()
        await pane.newFolderWithSelection([a, b])

        let folder = dir.appendingPathComponent("untitled folder")
        expect(undoManager.canUndo, "undo registered")
        undoManager.undo()
        try await Task.sleep(for: .milliseconds(500))
        expect(fm.fileExists(atPath: a.path), "a restored to original folder")
        expect(fm.fileExists(atPath: b.path), "b restored to original folder")
        expect(!fm.fileExists(atPath: folder.path), "created folder removed")
        expect(undoManager.canRedo, "redo available")

        undoManager.redo()
        try await Task.sleep(for: .milliseconds(500))
        expect(fm.fileExists(atPath: folder.appendingPathComponent("a.txt").path),
               "redo moves a back into folder")
        expect(fm.fileExists(atPath: folder.appendingPathComponent("b.txt").path),
               "redo moves b back into folder")
    }

    await test("newFolderWithSelection keeps folder on partial move failure") {
        let dir = try makeTempDir()
        defer { try? fm.removeItem(at: dir) }
        let movable = dir.appendingPathComponent("movable.txt")
        let missing = dir.appendingPathComponent("missing.txt")
        try Data().write(to: movable)

        let pane = PaneState(url: dir)
        await pane.reload()
        await pane.newFolderWithSelection([movable, missing])

        let folder = dir.appendingPathComponent("untitled folder")
        expect(fm.fileExists(atPath: folder.path), "folder remains")
        expect(fm.fileExists(atPath: folder.appendingPathComponent("movable.txt").path),
               "movable item moved")
        expect(pane.opErrorMessage != nil, "partial failure surfaced")
    }
}
