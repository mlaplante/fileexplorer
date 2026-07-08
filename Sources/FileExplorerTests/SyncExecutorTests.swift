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
