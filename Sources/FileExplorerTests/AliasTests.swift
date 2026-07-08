import Foundation
import FileExplorerCore

@MainActor
func aliasTests() async {
    let fm = FileManager.default

    await test("symlink creates 'name alias' pointing at source") {
        let dir = try makeTempDir()
        defer { try? fm.removeItem(at: dir) }
        let src = dir.appendingPathComponent("file.txt")
        try Data("x".utf8).write(to: src)

        let results = FileOperationService.symlink([src])
        guard case .success(let link) = results[0].outcome else {
            expect(false, "symlink should succeed")
            return
        }

        expectEqual(link.lastPathComponent, "file alias", "Finder-style name")
        let dest = try fm.destinationOfSymbolicLink(atPath: link.path)
        expectEqual(URL(fileURLWithPath: dest, relativeTo: dir).standardizedFileURL.path,
                    src.standardizedFileURL.path, "resolves to source")
    }

    await test("symlink collision appends counter") {
        let dir = try makeTempDir()
        defer { try? fm.removeItem(at: dir) }
        let src = dir.appendingPathComponent("file.txt")
        try Data().write(to: src)

        _ = FileOperationService.symlink([src])
        let second = FileOperationService.symlink([src])
        guard case .success(let link) = second[0].outcome else {
            expect(false, "second symlink should succeed")
            return
        }

        expectEqual(link.lastPathComponent, "file alias 2", "suffix increments")
    }

    await test("symlink works for folders") {
        let dir = try makeTempDir()
        defer { try? fm.removeItem(at: dir) }
        let src = dir.appendingPathComponent("folder")
        try fm.createDirectory(at: src, withIntermediateDirectories: false)

        let results = FileOperationService.symlink([src])
        guard case .success(let link) = results[0].outcome else {
            expect(false, "folder symlink should succeed")
            return
        }

        let dest = try fm.destinationOfSymbolicLink(atPath: link.path)
        expectEqual(URL(fileURLWithPath: dest, relativeTo: dir).standardizedFileURL.path,
                    src.standardizedFileURL.path, "folder link resolves")
    }

    await test("symlink creation undo deletes the alias") {
        let dir = try makeTempDir()
        defer { try? fm.removeItem(at: dir) }
        let src = dir.appendingPathComponent("file.txt")
        try Data().write(to: src)

        let undoManager = UndoManager()
        let pane = PaneState(url: dir)
        pane.undoManager = undoManager
        await pane.reload()

        await pane.makeAliasSelected([src])
        let link = dir.appendingPathComponent("file alias")
        expect(fm.fileExists(atPath: link.path), "alias created")
        expect(undoManager.canUndo, "undo registered")

        undoManager.undo()
        try await Task.sleep(for: .milliseconds(400))
        expect(!fm.fileExists(atPath: link.path), "undo removed alias")
        expect(fm.fileExists(atPath: src.path), "source remains")
    }
}
