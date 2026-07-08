import Foundation
import FileExplorerCore

@MainActor
func folderComparatorTests() async {
    func file(_ path: String, size: Int64 = 1,
              modified: Date = Date(timeIntervalSince1970: 1000)) -> FolderComparator.Entry {
        .init(relativePath: path, size: size, modified: modified, isDirectory: false)
    }
    func dir(_ path: String) -> FolderComparator.Entry {
        .init(relativePath: path, size: 0,
              modified: Date(timeIntervalSince1970: 0), isDirectory: true)
    }

    await test("compare classifies only-left, only-right, differs, same") {
        let left = [file("a.txt"), file("b.txt", size: 10), file("c.txt")]
        let right = [file("a.txt"), file("b.txt", size: 20), file("d.txt")]
        let result = FolderComparator.compare(left: left, right: right)
        expectEqual(result.onlyLeft, ["c.txt"], "only left")
        expectEqual(result.onlyRight, ["d.txt"], "only right")
        expectEqual(result.differs, ["b.txt"], "size mismatch differs")
    }

    await test("mtime differences within tolerance are same") {
        let base = Date(timeIntervalSince1970: 1000)
        let left = [file("t.txt", modified: base)]
        let closeRight = [file("t.txt", modified: base.addingTimeInterval(1.5))]
        let farRight = [file("t.txt", modified: base.addingTimeInterval(3))]
        expect(FolderComparator.compare(left: left, right: closeRight).differs.isEmpty,
               "1.5s within 2s tolerance")
        expectEqual(FolderComparator.compare(left: left, right: farRight).differs,
                    ["t.txt"], "3s beyond tolerance differs")
    }

    await test("directories contribute existence only, never differs") {
        let left = [dir("sub"), file("sub/x.txt"), dir("leftonly")]
        let right = [dir("sub"), file("sub/x.txt", size: 9)]
        let result = FolderComparator.compare(left: left, right: right)
        expectEqual(result.onlyLeft, ["leftonly"], "dir existence")
        expectEqual(result.differs, ["sub/x.txt"], "nested file differs; dir itself never")
    }

    await test("badge classifies visible rows including container dirs") {
        var result = FolderComparator.Result()
        result.onlyLeft = ["solo.txt", "deep/nested.txt"]
        result.differs = ["changed.txt"]
        expectEqual(FolderComparator.badge(for: "solo.txt", isDirectory: false,
                                           side: .left, in: result),
                    .onlyHere, "own file")
        expectEqual(FolderComparator.badge(for: "changed.txt", isDirectory: false,
                                           side: .left, in: result),
                    .differs, "changed file")
        expectEqual(FolderComparator.badge(for: "deep", isDirectory: true,
                                           side: .left, in: result),
                    .containsChanges, "dir containing an only-left descendant")
        expect(FolderComparator.badge(for: "solo.txt", isDirectory: false,
                                      side: .right, in: result) == nil,
               "left-only file has no badge on the right side")
    }

    await test("syncPlan prunes descendants of only-source dirs and orders copies") {
        var result = FolderComparator.Result()
        result.onlyLeft = ["dir", "dir/inner.txt", "dir/sub", "dir/sub/deep.txt",
                           "top.txt"]
        result.differs = ["changed.txt"]
        let plan = FolderComparator.syncPlan(result: result, direction: .leftToRight)
        expectEqual(plan.map(\.relativePath), ["changed.txt", "dir", "top.txt"],
                    "descendants pruned, sorted")
        expectEqual(plan.first { $0.relativePath == "changed.txt" }?.kind,
                    .overwrite, "differs → overwrite")
        expectEqual(plan.first { $0.relativePath == "dir" }?.kind,
                    .copy, "only-source → copy")
    }

    await test("syncPlan right-to-left draws from onlyRight") {
        var result = FolderComparator.Result()
        result.onlyLeft = ["l.txt"]
        result.onlyRight = ["r.txt"]
        result.differs = ["both.txt"]
        let plan = FolderComparator.syncPlan(result: result, direction: .rightToLeft)
        expectEqual(Set(plan.map(\.relativePath)), ["r.txt", "both.txt"],
                    "onlyRight + differs")
    }

    await test("listing walks recursively with relative paths") {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("fx-cmp-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try "x".write(to: root.appendingPathComponent("top.txt"),
                      atomically: true, encoding: .utf8)
        let sub = root.appendingPathComponent("sub")
        try FileManager.default.createDirectory(at: sub, withIntermediateDirectories: true)
        try "yy".write(to: sub.appendingPathComponent("inner.txt"),
                       atomically: true, encoding: .utf8)
        let entries = FolderComparator.listing(root: root, includeHidden: false)
        let paths = Set(entries.map(\.relativePath))
        expectEqual(paths, ["top.txt", "sub", "sub/inner.txt"], "relative paths")
        expectEqual(entries.first { $0.relativePath == "sub/inner.txt" }?.size, 2,
                    "sizes read")
        expect(entries.first { $0.relativePath == "sub" }?.isDirectory == true,
               "dir flagged")
    }
}
