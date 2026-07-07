import Foundation
import FileExplorerCore

@MainActor
func directoryLoaderTests() async {
    await test("DirectoryLoader loads entries with attributes") {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        try Data("hello".utf8).write(to: dir.appendingPathComponent("a.txt"))
        try FileManager.default.createDirectory(
            at: dir.appendingPathComponent("sub"), withIntermediateDirectories: false)
        try Data().write(to: dir.appendingPathComponent(".secret"))

        let visible = try DirectoryLoader.load(dir, includeHidden: false)
        expectEqual(visible.count, 2, "hidden file excluded by default")

        let names = Set(visible.map(\.name))
        expect(names == ["a.txt", "sub"], "names match [got: \(names)]")

        let file = visible.first { $0.name == "a.txt" }!
        expect(!file.isDirectory, "a.txt is not a directory")
        expectEqual(file.size, 5, "a.txt size is 5 bytes")
        expect(file.modified > Date(timeIntervalSince1970: 0), "modified date is set")
        expect(file.contentType?.conforms(to: .plainText) == true, "a.txt is plain text")

        let sub = visible.first { $0.name == "sub" }!
        expect(sub.isDirectory, "sub is a directory")

        let all = try DirectoryLoader.load(dir, includeHidden: true)
        expectEqual(all.count, 3, "hidden file included when asked")
        expect(all.first { $0.name == ".secret" }?.isHidden == true, ".secret flagged hidden")
    }

    await test("DirectoryLoader throws for missing directory") {
        let missing = URL(fileURLWithPath: "/nonexistent-\(UUID().uuidString)")
        do {
            _ = try DirectoryLoader.load(missing, includeHidden: false)
            expect(false, "should have thrown")
        } catch {
            expect(true, "threw as expected")
        }
    }

    await test("DirectoryLoader resolves symlink directories and kinds") {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let target = dir.appendingPathComponent("real-folder")
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: false)
        try FileManager.default.createSymbolicLink(
            at: dir.appendingPathComponent("link-to-folder"),
            withDestinationURL: target)
        try Data().write(to: dir.appendingPathComponent("plainfile"))

        let entries = try DirectoryLoader.load(dir, includeHidden: false)

        let link = entries.first { $0.name == "link-to-folder" }!
        expect(link.isSymlink, "symlink flagged as symlink")
        expect(link.isDirectory, "symlink to directory is navigable (isDirectory)")
        expectEqual(link.kind, "Folder", "symlink to directory reads as Folder")

        let folder = entries.first { $0.name == "real-folder" }!
        expectEqual(folder.kind, "Folder", "real directory kind is Folder")

        let plain = entries.first { $0.name == "plainfile" }!
        expect(!plain.kind.isEmpty, "extensionless file still gets a non-empty kind")
    }
}

func makeTempDir() throws -> URL {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("fx-tests-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
}
