import Foundation
import FileExplorerCore

@MainActor
func scannerTests() async {
    await test("FolderScanner finds nested folders within depth, skipping hidden") {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let fm = FileManager.default
        try fm.createDirectory(at: dir.appendingPathComponent("one/two/three/four"),
                               withIntermediateDirectories: true)
        try fm.createDirectory(at: dir.appendingPathComponent(".hiddenDir"),
                               withIntermediateDirectories: false)
        try Data().write(to: dir.appendingPathComponent("file.txt"))

        let found = FolderScanner.subfolders(of: dir, maxDepth: 3, cap: 100)
        let names = Set(found.map(\.lastPathComponent))
        expect(names.contains("one"), "depth 1 found")
        expect(names.contains("two"), "depth 2 found")
        expect(names.contains("three"), "depth 3 found")
        expect(!names.contains("four"), "depth 4 beyond maxDepth")
        expect(!names.contains(".hiddenDir"), "hidden dirs skipped")
        expect(!names.contains("file.txt"), "files not included")
    }

    await test("FolderScanner respects the cap") {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        for index in 0..<10 {
            try FileManager.default.createDirectory(
                at: dir.appendingPathComponent("d\(index)"),
                withIntermediateDirectories: false)
        }
        expectEqual(FolderScanner.subfolders(of: dir, maxDepth: 2, cap: 4).count, 4,
                    "cap enforced")
    }

    await test("FileSearcher finds files recursively, skipping hidden, capped") {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let fm = FileManager.default
        try fm.createDirectory(at: dir.appendingPathComponent("nested/deep"),
                               withIntermediateDirectories: true)
        try Data().write(to: dir.appendingPathComponent("top.txt"))
        try Data().write(to: dir.appendingPathComponent("nested/mid.txt"))
        try Data().write(to: dir.appendingPathComponent("nested/deep/bottom.txt"))
        try Data().write(to: dir.appendingPathComponent(".hidden.txt"))

        let all = FileSearcher.files(under: dir, cap: 100)
        let names = Set(all.map(\.lastPathComponent))
        expect(names.contains("top.txt") && names.contains("mid.txt")
               && names.contains("bottom.txt"), "recursive files found")
        expect(!names.contains(".hidden.txt"), "hidden skipped")
        expect(!names.contains("nested"), "directories excluded")

        expectEqual(FileSearcher.files(under: dir, cap: 2).count, 2, "cap enforced")
    }
}
