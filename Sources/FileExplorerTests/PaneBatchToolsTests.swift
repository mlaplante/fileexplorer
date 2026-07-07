import Foundation
import FileExplorerCore

@MainActor
func paneBatchToolsTests() async {
    let fm = FileManager.default

    await test("batchRename applies non-conflicted items as one undo step") {
        let dir = try makeTempDir()
        defer { try? fm.removeItem(at: dir) }
        try Data().write(to: dir.appendingPathComponent("IMG_1.jpg"))
        try Data().write(to: dir.appendingPathComponent("IMG_2.jpg"))
        try Data().write(to: dir.appendingPathComponent("skip.txt"))

        let undoManager = UndoManager()
        let pane = PaneState(url: dir)
        pane.undoManager = undoManager
        await pane.reload()

        var rules = RenameRules()
        rules.find = "IMG_"
        rules.replace = "Photo-"
        await pane.batchRename(
            [dir.appendingPathComponent("IMG_1.jpg"),
             dir.appendingPathComponent("IMG_2.jpg"),
             dir.appendingPathComponent("skip.txt")], rules: rules)

        expect(fm.fileExists(atPath: dir.appendingPathComponent("Photo-1.jpg").path),
               "first renamed")
        expect(fm.fileExists(atPath: dir.appendingPathComponent("Photo-2.jpg").path),
               "second renamed")
        expect(fm.fileExists(atPath: dir.appendingPathComponent("skip.txt").path),
               "unchanged item skipped, not errored")
        expectEqual(pane.selection,
                    [dir.appendingPathComponent("Photo-1.jpg").standardizedFileURL,
                     dir.appendingPathComponent("Photo-2.jpg").standardizedFileURL],
                    "renamed files selected")
        expect(pane.opErrorMessage == nil, "no error for skipped-unchanged")

        undoManager.undo()
        try await Task.sleep(for: .milliseconds(400))
        expect(fm.fileExists(atPath: dir.appendingPathComponent("IMG_1.jpg").path)
               && fm.fileExists(atPath: dir.appendingPathComponent("IMG_2.jpg").path),
               "single undo restores both")
    }

    await test("convertSelected and compressSelected register creation undo") {
        let dir = try makeTempDir()
        defer { try? fm.removeItem(at: dir) }
        let png = dir.appendingPathComponent("pic.png")
        try writeTestPNG(to: png, width: 16, height: 16)

        let undoManager = UndoManager()
        let pane = PaneState(url: dir)
        pane.undoManager = undoManager
        await pane.reload()

        await pane.convertSelected([png], to: .jpeg)
        let jpg = dir.appendingPathComponent("pic.jpg")
        expect(fm.fileExists(atPath: jpg.path), "converted")
        undoManager.undo()
        try await Task.sleep(for: .milliseconds(400))
        expect(!fm.fileExists(atPath: jpg.path), "undo removed the converted file")
        expect(fm.fileExists(atPath: png.path), "source untouched by undo")

        await pane.compressSelected([png])
        let archive = dir.appendingPathComponent("Archive.zip")
        expect(fm.fileExists(atPath: archive.path), "archive created")
        undoManager.undo()
        try await Task.sleep(for: .milliseconds(400))
        expect(!fm.fileExists(atPath: archive.path), "undo removed the archive")
    }

    await test("calculateFolderSizes caches and navigation clears") {
        let dir = try makeTempDir()
        defer { try? fm.removeItem(at: dir) }
        let sub = dir.appendingPathComponent("sub")
        try fm.createDirectory(at: sub, withIntermediateDirectories: false)
        try Data(count: 123).write(to: sub.appendingPathComponent("f.bin"))

        let pane = PaneState(url: dir)
        await pane.reload()
        await pane.calculateFolderSizes([sub])
        expectEqual(pane.folderSizes[sub.standardizedFileURL], 123, "size cached")

        await pane.navigate(to: sub)
        expect(pane.folderSizes.isEmpty, "cache cleared on navigation")
    }

    await test("openSelection navigates into a single selected folder") {
        let dir = try makeTempDir()
        defer { try? fm.removeItem(at: dir) }
        let sub = dir.appendingPathComponent("sub")
        try fm.createDirectory(at: sub, withIntermediateDirectories: false)
        try Data().write(to: dir.appendingPathComponent("f.txt"))

        let pane = PaneState(url: dir)
        await pane.reload()
        pane.selection = [sub.standardizedFileURL]
        var opened: [URL] = []
        await pane.openSelection { opened.append($0) }
        expectEqual(pane.currentURL, sub.standardizedFileURL, "navigated into folder")
        expect(opened.isEmpty, "no external opens for a folder")

        await pane.goBack()
        pane.selection = [dir.appendingPathComponent("f.txt").standardizedFileURL]
        await pane.openSelection { opened.append($0) }
        expectEqual(opened.count, 1, "file opened externally")
        expectEqual(pane.currentURL, dir.standardizedFileURL, "no navigation for a file")
    }
}
