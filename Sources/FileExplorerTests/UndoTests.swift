import Foundation
import FileExplorerCore

@MainActor
func undoTests() async {
    let fm = FileManager.default

    await test("PaneState move + undo round-trips through the UndoManager") {
        let dir = try makeTempDir()
        defer { try? fm.removeItem(at: dir) }
        let sub = dir.appendingPathComponent("sub")
        try fm.createDirectory(at: sub, withIntermediateDirectories: false)
        try Data().write(to: dir.appendingPathComponent("m.txt"))

        let undoManager = UndoManager()
        let pane = PaneState(url: dir)
        pane.undoManager = undoManager
        await pane.reload()

        await pane.moveSelected([dir.appendingPathComponent("m.txt")], into: sub)
        expect(fm.fileExists(atPath: sub.appendingPathComponent("m.txt").path),
               "moved into sub")
        expect(undoManager.canUndo, "undo registered")

        undoManager.undo()
        try await Task.sleep(for: .milliseconds(400))   // undo op is async inside
        expect(fm.fileExists(atPath: dir.appendingPathComponent("m.txt").path),
               "undo moved it back")
        expect(undoManager.canRedo, "redo available")
    }

    await test("PaneState trash + undo restores the file") {
        let dir = try makeTempDir()
        defer { try? fm.removeItem(at: dir) }
        let doomed = dir.appendingPathComponent("t.txt")
        try Data("keep me".utf8).write(to: doomed)

        let undoManager = UndoManager()
        let pane = PaneState(url: dir)
        pane.undoManager = undoManager
        await pane.reload()

        await pane.trashSelected([doomed])
        expect(!fm.fileExists(atPath: doomed.path), "trashed")
        expect(undoManager.canUndo, "undo registered")

        undoManager.undo()
        try await Task.sleep(for: .milliseconds(400))
        expect(fm.fileExists(atPath: doomed.path), "restored from trash")
        expectEqual(try? String(contentsOf: doomed, encoding: .utf8), "keep me",
                    "contents intact")
    }

    await test("newFolder undo trashes the created folder; failures don't register undo") {
        let dir = try makeTempDir()
        defer { try? fm.removeItem(at: dir) }
        let undoManager = UndoManager()
        let pane = PaneState(url: dir)
        pane.undoManager = undoManager
        await pane.reload()

        await pane.createNewFolder()
        let created = dir.appendingPathComponent("untitled folder")
        expect(fm.fileExists(atPath: created.path), "folder created")
        expect(undoManager.canUndo, "undo registered")
        undoManager.undo()
        try await Task.sleep(for: .milliseconds(400))
        expect(!fm.fileExists(atPath: created.path), "undo removed the folder")

        let before = undoManager.canUndo
        await pane.moveSelected([dir.appendingPathComponent("nope.txt")], into: dir)
        expectEqual(undoManager.canUndo, before,
                    "an all-failure operation registers no undo")
        expect(pane.opErrorMessage != nil, "failure surfaced to opErrorMessage")
    }

    await test("undoing New Folder / Rename leaves the correct Redo action name") {
        let dir = try makeTempDir()
        defer { try? fm.removeItem(at: dir) }
        let undoManager = UndoManager()
        let pane = PaneState(url: dir)
        pane.undoManager = undoManager
        await pane.reload()

        await pane.createNewFolder()
        expectEqual(undoManager.undoActionName, "New Folder", "undo labeled New Folder")
        undoManager.undo()
        try await Task.sleep(for: .milliseconds(400))
        expectEqual(undoManager.redoActionName, "New Folder",
                    "redo after undoing New Folder is still New Folder, not Move to Trash")

        let target = dir.appendingPathComponent("m.txt")
        try Data().write(to: target)
        await pane.reload()
        await pane.renameSelected(target, to: "renamed.txt")
        expectEqual(undoManager.undoActionName, "Rename", "undo labeled Rename")
        undoManager.undo()
        try await Task.sleep(for: .milliseconds(400))
        expectEqual(undoManager.redoActionName, "Rename",
                    "redo after undoing Rename is still Rename, not Move")
    }
}
