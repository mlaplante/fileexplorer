import Foundation
import FileExplorerCore

@MainActor
func syncExecutorTests() async {
    func makeTree(_ files: [String: String]) throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("fx-sync-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        for (path, contents) in files {
            let url = root.appendingPathComponent(path)
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try contents.write(to: url, atomically: true, encoding: .utf8)
        }
        return root
    }

    await test("execute copies only-source items and overwrites differs") {
        let source = try makeTree(["top.txt": "new", "dir/inner.txt": "nested",
                                   "changed.txt": "fresh"])
        let target = try makeTree(["changed.txt": "stale-old"])
        defer {
            try? FileManager.default.removeItem(at: source)
            try? FileManager.default.removeItem(at: target)
        }
        let plan = [
            FolderComparator.SyncOperation(relativePath: "changed.txt", kind: .overwrite),
            FolderComparator.SyncOperation(relativePath: "dir", kind: .copy),
            FolderComparator.SyncOperation(relativePath: "top.txt", kind: .copy),
        ]
        let outcome = SyncExecutor.execute(plan, from: source, to: target)
        expectEqual(outcome.failures, [], "no failures")
        expectEqual(try String(contentsOf: target.appendingPathComponent("changed.txt"),
                               encoding: .utf8), "fresh", "overwritten")
        expectEqual(try String(contentsOf: target.appendingPathComponent("dir/inner.txt"),
                               encoding: .utf8), "nested", "dir copied recursively")
        expectEqual(try String(contentsOf: target.appendingPathComponent("top.txt"),
                               encoding: .utf8), "new", "file copied")
        expectEqual(outcome.copied.count, 3, "three items created")
        expectEqual(outcome.trashed.count, 1, "old changed.txt trashed")
        expectEqual(outcome.trashed.first?.original.lastPathComponent, "changed.txt",
                    "trashed the overwritten target")
    }

    await test("sync-then-undo restores an overwritten file and removes the copy") {
        // Regression for the undo-grouping LIFO order: an overwrite item's
        // trash-restore must run AFTER the creation-undo vacates the path.
        let source = try makeTree(["changed.txt": "fresh"])
        let target = try makeTree(["changed.txt": "stale-old"])
        defer {
            try? FileManager.default.removeItem(at: source)
            try? FileManager.default.removeItem(at: target)
        }
        let tab = TabState(url: source)
        tab.toggleDual()
        await tab.panes[1].navigate(to: target)
        let undo = UndoManager()
        undo.groupsByEvent = false // tests have no run loop turns; group manually
        tab.panes[1].undoManager = undo
        await tab.runCompare()
        expectEqual(tab.compareResult?.differs, ["changed.txt"], "differs detected")
        await tab.syncCompare(direction: .leftToRight)
        let targetFile = target.appendingPathComponent("changed.txt")
        expectEqual(try String(contentsOf: targetFile, encoding: .utf8), "fresh",
                    "sync overwrote the target")
        expect(undo.canUndo, "sync registered undo")
        undo.undo()
        try await Task.sleep(for: .milliseconds(400))
        expectEqual(try String(contentsOf: targetFile, encoding: .utf8), "stale-old",
                    "undo restored the OLD file (not lost to the Trash)")
        expect(undo.canRedo, "redo available")
        undo.redo()
        try await Task.sleep(for: .milliseconds(400))
        expectEqual(try String(contentsOf: targetFile, encoding: .utf8), "fresh",
                    "redo re-applied the sync")
    }

    await test("syncCompare refuses to run after a pane navigated away") {
        // Regression for the stale-preview-sheet path: the plan was computed
        // against the compared roots; if a pane drifted, nothing may be
        // written into the new location.
        let source = try makeTree(["changed.txt": "fresh"])
        let target = try makeTree(["changed.txt": "stale-old"])
        let elsewhere = try makeTree([:])
        defer {
            try? FileManager.default.removeItem(at: source)
            try? FileManager.default.removeItem(at: target)
            try? FileManager.default.removeItem(at: elsewhere)
        }
        let tab = TabState(url: source)
        tab.toggleDual()
        await tab.panes[1].navigate(to: target)
        await tab.runCompare()
        expect(tab.compareResult != nil, "compare ran")
        await tab.panes[1].navigate(to: elsewhere)
        await tab.syncCompare(direction: .leftToRight)
        expect(!FileManager.default.fileExists(
                   atPath: elsewhere.appendingPathComponent("changed.txt").path),
               "nothing written into the drifted folder")
        expectEqual(try String(contentsOf: target.appendingPathComponent("changed.txt"),
                               encoding: .utf8), "stale-old",
                    "original target untouched")
        expect(tab.compareResult == nil, "compare mode ended after the bail")
    }

    await test("execute reports per-item failures without aborting") {
        let source = try makeTree(["ok.txt": "fine"])
        let target = try makeTree([:])
        defer {
            try? FileManager.default.removeItem(at: source)
            try? FileManager.default.removeItem(at: target)
        }
        let plan = [
            FolderComparator.SyncOperation(relativePath: "missing.txt", kind: .copy),
            FolderComparator.SyncOperation(relativePath: "ok.txt", kind: .copy),
        ]
        let outcome = SyncExecutor.execute(plan, from: source, to: target)
        expectEqual(outcome.failures.count, 1, "missing source fails")
        expectEqual(outcome.copied.count, 1, "good item still copied")
        expect(FileManager.default.fileExists(
                   atPath: target.appendingPathComponent("ok.txt").path),
               "ok.txt landed")
    }
}
