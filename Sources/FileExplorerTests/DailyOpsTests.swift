import Foundation
import FileExplorerCore

@MainActor
func dailyOpsTests() async {
    func makeScratch() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("fx-dailyops-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }
    func write(_ name: String, in dir: URL, contents: String = "x") throws -> URL {
        let url = dir.appendingPathComponent(name)
        try contents.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    await test("newFile creates untitled, then untitled 2") {
        let dir = try makeScratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        let first = FileOperationService.newFile(in: dir)
        guard case .success(let firstURL) = first else {
            return expect(false, "first newFile succeeds")
        }
        expectEqual(firstURL.lastPathComponent, "untitled", "first name")
        expect(FileManager.default.fileExists(atPath: firstURL.path), "file exists")
        let second = FileOperationService.newFile(in: dir)
        guard case .success(let secondURL) = second else {
            return expect(false, "second newFile succeeds")
        }
        expectEqual(secondURL.lastPathComponent, "untitled 2", "second name")
    }

    await test("copyAvoidingCollisions renames instead of failing") {
        let dir = try makeScratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        let source = try write("a.txt", in: dir, contents: "hello")
        let results = FileOperationService.copyAvoidingCollisions([source], into: dir)
        guard case .success(let copy) = results[0].outcome else {
            return expect(false, "copy into own folder succeeds via rename")
        }
        expectEqual(copy.lastPathComponent, "a copy.txt", "Finder-style name")
        expectEqual(try String(contentsOf: copy, encoding: .utf8), "hello",
                    "contents copied")
    }

    await test("copyAvoidingCollisions still refuses a folder into itself") {
        let dir = try makeScratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        let results = FileOperationService.copyAvoidingCollisions([dir], into: dir)
        guard case .failure = results[0].outcome else {
            return expect(false, "folder-into-itself is rejected")
        }
        expect(true, "rejected")
    }

    await test("pane duplicateSelected copies next to source, selects, undoes") {
        let dir = try makeScratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        let source = try write("doc.txt", in: dir)
        let pane = PaneState(url: dir)
        let undo = UndoManager()
        pane.undoManager = undo
        await pane.duplicateSelected([source])
        let copy = dir.appendingPathComponent("doc copy.txt")
        expect(FileManager.default.fileExists(atPath: copy.path), "duplicate exists")
        expectEqual(pane.selection, [copy.standardizedFileURL],
                    "duplicate is selected")
        expect(undo.canUndo, "duplicate registered undo")
        undo.undo()
        try await Task.sleep(for: .milliseconds(400))
        expect(!FileManager.default.fileExists(atPath: copy.path),
               "undo trashed the duplicate")
    }

    await test("pane createNewFile selects the new file and undoes") {
        let dir = try makeScratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        let pane = PaneState(url: dir)
        let undo = UndoManager()
        pane.undoManager = undo
        await pane.createNewFile()
        let created = dir.appendingPathComponent("untitled")
        expect(FileManager.default.fileExists(atPath: created.path), "file created")
        expectEqual(pane.selection, [created.standardizedFileURL], "selected")
        undo.undo()
        try await Task.sleep(for: .milliseconds(400))
        expect(!FileManager.default.fileExists(atPath: created.path),
               "undo trashed the new file")
    }

    await test("pane pasteCopy into same folder auto-renames and undoes") {
        let dir = try makeScratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        let source = try write("p.txt", in: dir)
        let pane = PaneState(url: dir)
        let undo = UndoManager()
        pane.undoManager = undo
        await pane.pasteCopy([source])
        let pasted = dir.appendingPathComponent("p copy.txt")
        expect(FileManager.default.fileExists(atPath: pasted.path), "pasted copy exists")
        expect(pane.opErrorMessage == nil, "no error reported")
        expect(undo.canUndo, "paste registered undo")
    }
}
