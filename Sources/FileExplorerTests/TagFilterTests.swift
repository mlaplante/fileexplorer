import Foundation
import FileExplorerCore

@MainActor
func tagFilterTests() async {
    func entry(_ name: String, tags: [String] = [],
               isDirectory: Bool = false) -> FileEntry {
        FileEntry(url: URL(fileURLWithPath: "/tmp/\(name)"), name: name,
                  isDirectory: isDirectory, isHidden: false, isSymlink: false,
                  size: 1, created: nil, modified: Date(), contentType: nil,
                  tags: tags)
    }

    await test("tag filter keeps entries carrying any selected tag") {
        var filter = FilterState()
        filter.tags = ["Red", "Work"]
        let entries = [
            entry("red.txt", tags: ["Red"]),
            entry("work.txt", tags: ["Work", "Blue"]),
            entry("blue.txt", tags: ["Blue"]),
            entry("plain.txt"),
        ]
        let names = FilterEngine.apply(filter, to: entries).map(\.name)
        expectEqual(names, ["red.txt", "work.txt"], "any-of tag match")
    }

    await test("folders always pass the tag filter") {
        var filter = FilterState()
        filter.tags = ["Red"]
        let entries = [entry("folder", isDirectory: true), entry("file.txt")]
        let names = FilterEngine.apply(filter, to: entries).map(\.name)
        expectEqual(names, ["folder"], "folder passes, untagged file filtered")
    }

    await test("tags participate in isActive") {
        var filter = FilterState()
        expect(!filter.isActive, "empty filter inactive")
        filter.tags = ["Red"]
        expect(filter.isActive, "tag selection activates the filter")
    }

    await test("FilterState without tags key still decodes (forward compat)") {
        let old = #"{"extensions":["png"]}"#
        let decoded = try JSONDecoder().decode(
            FilterState.self, from: Data(old.utf8))
        expectEqual(decoded.extensions, ["png"], "old payload decodes")
        expect(decoded.tags == nil, "missing tags key → nil")

        var filter = FilterState()
        filter.tags = ["Red"]
        let data = try JSONEncoder().encode(filter)
        let roundTrip = try JSONDecoder().decode(FilterState.self, from: data)
        expectEqual(roundTrip, filter, "tags round-trip")
    }

    await test("TagWriter round-trips through DirectoryLoader") {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("fx-tags-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("tagged.txt")
        try "x".write(to: file, atomically: true, encoding: .utf8)

        guard case .success = TagWriter.setTags(["Red", "Work"], on: file) else {
            return expect(false, "setTags succeeds")
        }
        let loaded = try DirectoryLoader.load(dir, includeHidden: false)
        expectEqual(loaded.first?.tags.sorted(), ["Red", "Work"],
                    "tags read back by the loader")

        guard case .success = TagWriter.setTags([], on: file) else {
            return expect(false, "clearing tags succeeds")
        }
        let cleared = try DirectoryLoader.load(dir, includeHidden: false)
        expectEqual(cleared.first?.tags ?? ["sentinel"], [],
                    "tags cleared")
    }

    await test("PaneState merges loaded entry tags into known settings tags") {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let persister = SessionPersister(
            directory: dir.appendingPathComponent("settings"))
        let settings = SettingsModel(persister: persister)
        let pane = PaneState(url: dir)
        pane.settingsModel = settings

        let file = dir.appendingPathComponent("tagged.txt")
        try Data().write(to: file)
        _ = TagWriter.setTags(["Red", "projx"], on: file)

        await pane.reload()
        expectEqual(settings.settings.knownTags, ["projx", "Red"],
                    "loaded tags merged into settings")
    }
}
