import Foundation
import FileExplorerCore

@MainActor
func fileOperationTests() async {
    let fm = FileManager.default

    await test("move relocates files and reports per-item results") {
        let dir = try makeTempDir()
        defer { try? fm.removeItem(at: dir) }
        let src = dir.appendingPathComponent("src")
        let dst = dir.appendingPathComponent("dst")
        try fm.createDirectory(at: src, withIntermediateDirectories: false)
        try fm.createDirectory(at: dst, withIntermediateDirectories: false)
        try Data().write(to: src.appendingPathComponent("a.txt"))
        try Data().write(to: src.appendingPathComponent("b.txt"))
        try Data().write(to: dst.appendingPathComponent("b.txt"))   // collision

        let results = FileOperationService.move(
            [src.appendingPathComponent("a.txt"), src.appendingPathComponent("b.txt")],
            into: dst)
        expectEqual(results.count, 2, "one result per item")

        let moved = results.first { $0.source.lastPathComponent == "a.txt" }!
        switch moved.outcome {
        case .success(let newURL):
            expectEqual(newURL.lastPathComponent, "a.txt", "moved to dst")
            expect(fm.fileExists(atPath: dst.appendingPathComponent("a.txt").path),
                   "file exists at destination")
            expect(!fm.fileExists(atPath: src.appendingPathComponent("a.txt").path),
                   "gone from source")
        case .failure:
            expect(false, "a.txt should move cleanly")
        }

        let collided = results.first { $0.source.lastPathComponent == "b.txt" }!
        if case .success = collided.outcome {
            expect(false, "collision must fail, not overwrite")
        } else {
            expect(fm.fileExists(atPath: src.appendingPathComponent("b.txt").path),
                   "source untouched on collision")
        }
    }

    await test("copy duplicates; rename renames; newFolder creates uniquely") {
        let dir = try makeTempDir()
        defer { try? fm.removeItem(at: dir) }
        try Data("x".utf8).write(to: dir.appendingPathComponent("orig.txt"))

        let copies = FileOperationService.copy(
            [dir.appendingPathComponent("orig.txt")], into: dir)
        if case .failure = copies[0].outcome {
            expect(true, "copy into same folder collides with itself — failure OK")
        }
        let dst = dir.appendingPathComponent("sub")
        try fm.createDirectory(at: dst, withIntermediateDirectories: false)
        let copied = FileOperationService.copy(
            [dir.appendingPathComponent("orig.txt")], into: dst)
        if case .success(let url) = copied[0].outcome {
            expect(fm.fileExists(atPath: url.path), "copy exists")
            expect(fm.fileExists(atPath: dir.appendingPathComponent("orig.txt").path),
                   "original remains")
        } else { expect(false, "copy should succeed") }

        let renamed = FileOperationService.rename(
            dir.appendingPathComponent("orig.txt"), to: "renamed.txt")
        if case .success(let url) = renamed {
            expectEqual(url.lastPathComponent, "renamed.txt", "renamed")
        } else { expect(false, "rename should succeed") }
        if case .success = FileOperationService.rename(
            dir.appendingPathComponent("renamed.txt"), to: "renamed.txt") {
            expect(false, "rename to same name should fail")
        }

        let folder1 = FileOperationService.newFolder(in: dir)
        let folder2 = FileOperationService.newFolder(in: dir)
        if case .success(let f1) = folder1, case .success(let f2) = folder2 {
            expect(f1 != f2, "second untitled folder gets a unique name")
            expect(fm.fileExists(atPath: f2.path), "both exist")
        } else { expect(false, "newFolder should succeed twice") }
    }

    await test("trash returns the trash location for undo") {
        let dir = try makeTempDir()
        defer { try? fm.removeItem(at: dir) }
        let doomed = dir.appendingPathComponent("doomed.txt")
        try Data().write(to: doomed)

        let results = FileOperationService.trash([doomed])
        if case .success(let trashURL) = results[0].outcome {
            expect(!fm.fileExists(atPath: doomed.path), "gone from folder")
            expect(fm.fileExists(atPath: trashURL.path), "exists in trash")
            // restore (what undo will do)
            if case .success = FileOperationService.move([trashURL], into: dir)[0].outcome {
                expect(fm.fileExists(atPath: dir.appendingPathComponent(
                    trashURL.lastPathComponent).path), "restorable")
            } else { expect(false, "restore should succeed") }
        } else {
            expect(false, "trash should succeed")
        }
    }
}
