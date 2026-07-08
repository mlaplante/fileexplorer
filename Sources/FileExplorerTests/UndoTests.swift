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

    await test("undo rename restores the original filename on disk") {
        let dir = try makeTempDir()
        defer { try? fm.removeItem(at: dir) }
        let old = dir.appendingPathComponent("old.txt")
        try Data().write(to: old)
        let undoManager = UndoManager()
        let pane = PaneState(url: dir)
        pane.undoManager = undoManager
        await pane.reload()
        await pane.renameSelected(old, to: "new.txt")
        expect(fm.fileExists(atPath: dir.appendingPathComponent("new.txt").path), "renamed")
        undoManager.undo()
        try await Task.sleep(for: .milliseconds(400))
        expect(fm.fileExists(atPath: old.path), "old.txt restored ON DISK")
        expect(!fm.fileExists(atPath: dir.appendingPathComponent("new.txt").path),
               "new.txt gone after undo")
    }

    await test("undo move into reoccupied source surfaces a failure") {
        let dir = try makeTempDir()
        defer { try? fm.removeItem(at: dir) }
        let sub = dir.appendingPathComponent("sub")
        try fm.createDirectory(at: sub, withIntermediateDirectories: false)
        let file = dir.appendingPathComponent("a.txt")
        try Data().write(to: file)
        let undoManager = UndoManager()
        let pane = PaneState(url: dir)
        pane.undoManager = undoManager
        await pane.reload()
        await pane.moveSelected([file], into: sub)
        try Data("squatter".utf8).write(to: file)   // reoccupy the source path
        undoManager.undo()
        try await Task.sleep(for: .milliseconds(400))
        expectEqual(try? String(contentsOf: file, encoding: .utf8), "squatter",
                    "squatter not overwritten")
        expect(fm.fileExists(atPath: sub.appendingPathComponent("a.txt").path),
               "moved file stays put when restore collides")
        expect(pane.opErrorMessage != nil, "undo failure surfaced")
    }

    await test("undo/redo of a batch-rename name handoff relocates via two-phase staging") {
        let dir = try makeTempDir()
        defer { try? fm.removeItem(at: dir) }
        let a = dir.appendingPathComponent("a.txt")
        let ax = dir.appendingPathComponent("ax.txt")
        let axx = dir.appendingPathComponent("axx.txt")
        try Data("ONE".utf8).write(to: a)
        try Data("TWO".utf8).write(to: ax)

        let undoManager = UndoManager()
        let pane = PaneState(url: dir)
        pane.undoManager = undoManager
        await pane.reload()

        var rules = RenameRules()
        rules.suffix = "x"
        // Order matters here: batchRename's outcome.pairs (and thus the
        // recorded undo `moves`) follow input order. With [ax, a] the undo
        // loop processes (ax.txt→axx.txt) BEFORE (a.txt→ax.txt), so its
        // restore target (ax.txt) is still occupied by the OTHER pair when
        // it's attempted — the exact collision a naive pair-by-pair undo
        // hits. [a, ax] would restore collision-free by luck of ordering
        // and wouldn't exercise the bug.
        await pane.batchRename([ax, a], rules: rules)

        expect(fm.fileExists(atPath: ax.path), "a.txt -> ax.txt")
        expect(fm.fileExists(atPath: axx.path), "ax.txt -> axx.txt")
        expectEqual(try? String(contentsOf: ax, encoding: .utf8), "ONE",
                    "ax.txt holds a.txt's original content")
        expectEqual(try? String(contentsOf: axx, encoding: .utf8), "TWO",
                    "axx.txt holds ax.txt's original content")
        expect(pane.opErrorMessage == nil, "no failure from the rename itself")
        expect(undoManager.canUndo, "undo registered")

        undoManager.undo()
        try await Task.sleep(for: .milliseconds(400))
        expect(fm.fileExists(atPath: a.path), "a.txt restored")
        expect(fm.fileExists(atPath: ax.path), "ax.txt restored")
        expect(!fm.fileExists(atPath: axx.path), "axx.txt gone after undo")
        expectEqual(try? String(contentsOf: a, encoding: .utf8), "ONE",
                    "a.txt has its original content back")
        expectEqual(try? String(contentsOf: ax, encoding: .utf8), "TWO",
                    "ax.txt has its original content back")
        expect(pane.opErrorMessage == nil, "undo reported no failure")
        expect(undoManager.canRedo, "redo available")

        undoManager.redo()
        try await Task.sleep(for: .milliseconds(400))
        expect(fm.fileExists(atPath: ax.path), "redo re-applies a.txt -> ax.txt")
        expect(fm.fileExists(atPath: axx.path), "redo re-applies ax.txt -> axx.txt")
        expectEqual(try? String(contentsOf: ax, encoding: .utf8), "ONE",
                    "ax.txt has a.txt's content again after redo")
        expectEqual(try? String(contentsOf: axx, encoding: .utf8), "TWO",
                    "axx.txt has ax.txt's content again after redo")
        expect(pane.opErrorMessage == nil, "redo reported no failure")
    }
}
