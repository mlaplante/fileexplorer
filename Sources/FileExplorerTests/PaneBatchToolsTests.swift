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

    await test("convertSelected selects its outputs") {
        let dir = try makeTempDir()
        defer { try? fm.removeItem(at: dir) }
        let png = dir.appendingPathComponent("shot.png")
        try writeTestPNG(to: png, width: 16, height: 16)

        let pane = PaneState(url: dir)
        await pane.reload()
        await pane.convertSelected([png], to: .jpeg, jpegQuality: 0.9)

        expectEqual(pane.selection,
                    [dir.appendingPathComponent("shot.jpg").standardizedFileURL],
                    "converted output selected")
        expect(pane.opErrorMessage == nil, "no error on clean conversion")
    }

    await test("executeResolvedPlan copies and registers creation undo") {
        let dir = try makeTempDir()
        defer { try? fm.removeItem(at: dir) }
        let src = dir.appendingPathComponent("src")
        let dst = dir.appendingPathComponent("dst")
        try fm.createDirectory(at: src, withIntermediateDirectories: false)
        try fm.createDirectory(at: dst, withIntermediateDirectories: false)
        let source = src.appendingPathComponent("a.txt")
        let target = dst.appendingPathComponent("a.txt")
        try Data("copy".utf8).write(to: source)

        let undoManager = UndoManager()
        let pane = PaneState(url: dst)
        pane.undoManager = undoManager
        await pane.reload()
        let plan = OperationConflictPlanner.Plan(operation: .copy, destination: dst,
                                                 items: [
            .init(source: source, action: .write(to: target)),
        ])

        await pane.executeResolvedPlan(plan, actionName: "Copy")
        expect(fm.fileExists(atPath: target.path), "planned copy created target")
        expectEqual(pane.selection, [target.standardizedFileURL],
                    "created target selected")
        undoManager.undo()
        try await Task.sleep(for: .milliseconds(400))
        expect(!fm.fileExists(atPath: target.path), "undo removed copied target")
        expect(fm.fileExists(atPath: source.path), "source remains after copy undo")
    }

    await test("executeResolvedPlan replace undo restores old destination") {
        let dir = try makeTempDir()
        defer { try? fm.removeItem(at: dir) }
        let src = dir.appendingPathComponent("src")
        let dst = dir.appendingPathComponent("dst")
        try fm.createDirectory(at: src, withIntermediateDirectories: false)
        try fm.createDirectory(at: dst, withIntermediateDirectories: false)
        let source = src.appendingPathComponent("a.txt")
        let target = dst.appendingPathComponent("a.txt")
        try Data("new".utf8).write(to: source)
        try Data("old".utf8).write(to: target)

        let undoManager = UndoManager()
        let pane = PaneState(url: dst)
        pane.undoManager = undoManager
        await pane.reload()
        let plan = OperationConflictPlanner.Plan(operation: .copy, destination: dst,
                                                 items: [
            .init(source: source, action: .replace(existing: target)),
        ])

        await pane.executeResolvedPlan(plan, actionName: "Copy")
        expectEqual(try String(contentsOf: target, encoding: .utf8), "new",
                    "target replaced")
        undoManager.undo()
        try await Task.sleep(for: .milliseconds(500))
        expectEqual(try String(contentsOf: target, encoding: .utf8), "old",
                    "undo restores old destination")
    }

    await test("trash urls entry point registers undo registry and partial failures") {
        let dir = try makeTempDir()
        defer { try? fm.removeItem(at: dir) }
        let keepGoing = dir.appendingPathComponent("keep-going.txt")
        let missing = dir.appendingPathComponent("missing.txt")
        try Data("body".utf8).write(to: keepGoing)

        let undoManager = UndoManager()
        let registry = TrashRegistryModel(directory: dir.appendingPathComponent("registry"))
        let pane = PaneState(url: dir)
        pane.undoManager = undoManager
        pane.trashRegistry = registry
        await pane.reload()

        await pane.trash(urls: [missing, keepGoing])

        expect(!fm.fileExists(atPath: keepGoing.path), "existing file moved to trash")
        let record = registry.registry.records.first
        expectEqual(record?.original, keepGoing.standardizedFileURL,
                    "trash registry records original")
        expect(record?.trashed.pathComponents.contains(".Trash") == true,
               "trash registry records trashed location")
        expect(record.map { fm.fileExists(atPath: $0.trashed.path) } == true,
               "trashed file exists at recorded path")
        expect(undoManager.canUndo, "undo registered for successful trash")
        expect(pane.opErrorMessage != nil, "missing URL failure surfaced")

        undoManager.undo()
        await waitForPaneBatchCondition {
            fm.fileExists(atPath: keepGoing.path)
        }
        expect(fm.fileExists(atPath: keepGoing.path), "undo restores trashed file")
        expectEqual(try? String(contentsOf: keepGoing, encoding: .utf8), "body",
                    "undo preserves contents")
    }
}

@MainActor
private func waitForPaneBatchCondition(_ condition: @escaping @MainActor () -> Bool) async {
    let deadline = Date().addingTimeInterval(5)
    while !condition(), Date() < deadline {
        try? await Task.sleep(for: .milliseconds(10))
    }
}
