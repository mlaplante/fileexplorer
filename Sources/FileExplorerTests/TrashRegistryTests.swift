import Foundation
import FileExplorerCore

@MainActor
func trashRegistryTests() async {
    let fm = FileManager.default

    await test("TrashRegistry record lookup save and load round-trips") {
        let dir = try makeTempDir()
        defer { try? fm.removeItem(at: dir) }
        let original = URL(fileURLWithPath: "/tmp/original.txt")
        let trashed = URL(fileURLWithPath: "/Users/me/.Trash/original.txt")

        var registry = TrashRegistry()
        registry.record(original: original, trashed: trashed)
        expectEqual(registry.original(forTrashed: trashed), original,
                    "lookup returns recorded original")
        registry.save(to: dir)

        let loaded = TrashRegistry.load(from: dir)
        expectEqual(loaded.original(forTrashed: trashed), original,
                    "saved registry reloads")
    }

    await test("TrashRegistry corrupt JSON loads as empty") {
        let dir = try makeTempDir()
        defer { try? fm.removeItem(at: dir) }
        try Data("not json".utf8).write(to: dir.appendingPathComponent("trash-registry.json"))
        let registry = TrashRegistry.load(from: dir)
        expect(registry.isEmpty, "corrupt registry file degrades to empty")
    }

    await test("TrashRegistry prune drops records whose trashed file vanished") {
        let dir = try makeTempDir()
        defer { try? fm.removeItem(at: dir) }
        let trashed = dir.appendingPathComponent(".Trash/kept.txt")
        try fm.createDirectory(at: trashed.deletingLastPathComponent(),
                               withIntermediateDirectories: true)
        try Data().write(to: trashed)
        var registry = TrashRegistry()
        registry.record(original: URL(fileURLWithPath: "/tmp/kept.txt"),
                        trashed: trashed)
        try fm.removeItem(at: trashed)

        registry.prune()
        expect(registry.isEmpty, "missing trashed path was pruned")
    }

    await test("TrashRegistry detects Trash path components") {
        expect(TrashRegistry.isInTrash(URL(fileURLWithPath: "/Users/me/.Trash/a.txt")),
               ".Trash component is trash")
        expect(TrashRegistry.isInTrash(URL(fileURLWithPath: "/Volumes/Disk/Trash/a.txt")),
               "Trash component is trash")
        expect(!TrashRegistry.isInTrash(URL(fileURLWithPath: "/tmp/Trashy/a.txt")),
               "partial component does not count")
    }

    await test("PaneState trash records original and trashed URLs") {
        let dir = try makeTempDir()
        defer { try? fm.removeItem(at: dir) }
        let file = dir.appendingPathComponent("gone.txt")
        try Data().write(to: file)
        let registry = TrashRegistryModel(directory: dir.appendingPathComponent("registry"))
        let pane = PaneState(url: dir)
        pane.trashRegistry = registry
        await pane.reload()

        await pane.trashSelected([file])
        let record = registry.registry.records.first
        expect(record?.original == file.standardizedFileURL,
               "registry captured original URL")
        expect(record?.trashed.pathComponents.contains(".Trash") == true,
               "registry captured trashed URL")
    }

    await test("PaneState putBackSelected restores recorded trash item") {
        let dir = try makeTempDir()
        defer { try? fm.removeItem(at: dir) }
        let file = dir.appendingPathComponent("restore.txt")
        try Data("body".utf8).write(to: file)
        let undoManager = UndoManager()
        let registry = TrashRegistryModel(directory: dir.appendingPathComponent("registry"))
        let pane = PaneState(url: dir)
        pane.undoManager = undoManager
        pane.trashRegistry = registry
        await pane.reload()
        await pane.trashSelected([file])
        guard let trashed = registry.registry.records.first?.trashed else {
            expect(false, "expected trashed record")
            return
        }

        await pane.putBackSelected([trashed])
        expect(fm.fileExists(atPath: file.path), "file restored to original path")
        expectEqual(try? String(contentsOf: file, encoding: .utf8), "body",
                    "contents preserved")
        expect(registry.registry.original(forTrashed: trashed) == nil,
               "record removed after successful Put Back")
        expect(undoManager.canUndo, "put back registers undo")

        undoManager.undo()
        try await Task.sleep(for: .milliseconds(400))
        expect(!fm.fileExists(atPath: file.path), "undo re-trashes restored item")
    }

    await test("PaneState putBackSelected keeps record when original path is occupied") {
        let dir = try makeTempDir()
        defer { try? fm.removeItem(at: dir) }
        let original = dir.appendingPathComponent("occupied.txt")
        let trashed = dir.appendingPathComponent(".Trash/occupied.txt")
        try fm.createDirectory(at: trashed.deletingLastPathComponent(),
                               withIntermediateDirectories: true)
        try Data("trash".utf8).write(to: trashed)
        try Data("squatter".utf8).write(to: original)
        let registry = TrashRegistryModel(directory: dir.appendingPathComponent("registry"))
        registry.record(original: original, trashed: trashed)
        let pane = PaneState(url: dir)
        pane.trashRegistry = registry

        await pane.putBackSelected([trashed])
        expectEqual(try? String(contentsOf: original, encoding: .utf8), "squatter",
                    "occupied original was not overwritten")
        expect(fm.fileExists(atPath: trashed.path), "trashed file remains")
        expect(pane.opErrorMessage != nil, "failure surfaced to status bar")
        expectEqual(registry.registry.original(forTrashed: trashed), original,
                    "record kept after failure")
    }
}
