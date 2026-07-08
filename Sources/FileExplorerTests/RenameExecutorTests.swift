import Foundation
import FileExplorerCore

@MainActor
func renameExecutorTests() async {
    func makeDir(_ names: [String]) throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("m8-exec-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: dir, withIntermediateDirectories: true)
        for name in names {
            FileManager.default.createFile(
                atPath: dir.appendingPathComponent(name).path, contents: Data())
        }
        return dir
    }

    await test("executor performs a two-item swap via temp phase") {
        let dir = try makeDir(["a.txt", "b.txt"])
        defer { try? FileManager.default.removeItem(at: dir) }
        let items = [
            RenamePlan.Item(source: dir.appendingPathComponent("a.txt"),
                            newName: "b.txt", conflict: nil),
            RenamePlan.Item(source: dir.appendingPathComponent("b.txt"),
                            newName: "a.txt", conflict: nil),
        ]
        let outcome = RenameExecutor.execute(items)
        expectEqual(outcome.pairs.count, 2, "both renames succeed")
        expect(outcome.failures.isEmpty, "no failures")
        let names = try FileManager.default.contentsOfDirectory(atPath: dir.path)
        expectEqual(Set(names), ["a.txt", "b.txt"], "same names, swapped files")
    }

    await test("executor handles a three-cycle") {
        let dir = try makeDir(["1.txt", "2.txt", "3.txt"])
        defer { try? FileManager.default.removeItem(at: dir) }
        let items = [
            RenamePlan.Item(source: dir.appendingPathComponent("1.txt"),
                            newName: "2.txt", conflict: nil),
            RenamePlan.Item(source: dir.appendingPathComponent("2.txt"),
                            newName: "3.txt", conflict: nil),
            RenamePlan.Item(source: dir.appendingPathComponent("3.txt"),
                            newName: "1.txt", conflict: nil),
        ]
        let outcome = RenameExecutor.execute(items)
        expectEqual(outcome.pairs.count, 3, "cycle resolves")
        expect(outcome.failures.isEmpty, "no failures")
    }

    await test("executor rolls back to originals when a final target is blocked") {
        let dir = try makeDir(["a.txt", "blocker.txt"])
        defer { try? FileManager.default.removeItem(at: dir) }
        let items = [RenamePlan.Item(source: dir.appendingPathComponent("a.txt"),
                                     newName: "blocker.txt", conflict: nil)]
        let outcome = RenameExecutor.execute(items)
        expect(outcome.pairs.isEmpty, "no success recorded")
        expectEqual(outcome.failures.count, 1, "failure surfaced")
        expect(FileManager.default.fileExists(
                   atPath: dir.appendingPathComponent("a.txt").path),
               "source restored to its original name")
    }

    await test("executor skips conflicted and unchanged items") {
        let dir = try makeDir(["a.txt"])
        defer { try? FileManager.default.removeItem(at: dir) }
        let items = [
            RenamePlan.Item(source: dir.appendingPathComponent("a.txt"),
                            newName: "a.txt", conflict: .unchanged),
            RenamePlan.Item(source: dir.appendingPathComponent("ghost.txt"),
                            newName: "x.txt", conflict: .invalidName),
        ]
        let outcome = RenameExecutor.execute(items)
        expect(outcome.pairs.isEmpty && outcome.failures.count == 1,
               "unchanged silently skipped; conflicted reported")
    }

    await test("relocate performs a two-item swap to exact destination URLs") {
        let dir = try makeDir(["a.txt"])
        defer { try? FileManager.default.removeItem(at: dir) }
        let a = dir.appendingPathComponent("a.txt")
        let b = dir.appendingPathComponent("b.txt")
        try Data("ONE".utf8).write(to: a)
        try Data("TWO".utf8).write(to: b)
        let outcome = RenameExecutor.relocate([(from: a, to: b), (from: b, to: a)])
        expectEqual(outcome.pairs.count, 2, "both relocations succeed")
        expect(outcome.failures.isEmpty, "no failures")
        expectEqual(try? String(contentsOf: a, encoding: .utf8), "TWO",
                    "a.txt now holds what was in b.txt")
        expectEqual(try? String(contentsOf: b, encoding: .utf8), "ONE",
                    "b.txt now holds what was in a.txt")
    }

    await test("relocate handles a cross-directory move") {
        let dir = try makeDir(["a.txt"])
        defer { try? FileManager.default.removeItem(at: dir) }
        let sub = dir.appendingPathComponent("sub")
        try FileManager.default.createDirectory(at: sub, withIntermediateDirectories: false)
        let a = dir.appendingPathComponent("a.txt")
        let dest = sub.appendingPathComponent("a.txt")
        let outcome = RenameExecutor.relocate([(from: a, to: dest)])
        expectEqual(outcome.pairs.count, 1, "cross-directory relocation succeeds")
        expect(outcome.failures.isEmpty, "no failures")
        expect(FileManager.default.fileExists(atPath: dest.path), "file landed in sub")
        expect(!FileManager.default.fileExists(atPath: a.path), "gone from original location")
    }

    await test("relocate rolls back to the original URL when the final target is blocked") {
        let dir = try makeDir(["a.txt", "blocker.txt"])
        defer { try? FileManager.default.removeItem(at: dir) }
        let a = dir.appendingPathComponent("a.txt")
        let blocker = dir.appendingPathComponent("blocker.txt")
        let outcome = RenameExecutor.relocate([(from: a, to: blocker)])
        expect(outcome.pairs.isEmpty, "no success recorded")
        expectEqual(outcome.failures.count, 1, "failure surfaced")
        expect(FileManager.default.fileExists(atPath: a.path),
               "source restored to its original URL")
    }
}
