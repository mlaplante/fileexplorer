import Foundation
import FileExplorerCore

@MainActor
func infoGathererTests() async {
    await test("permissionString renders POSIX modes") {
        expectEqual(InfoGatherer.permissionString(mode: 0o755), "rwxr-xr-x", "755")
        expectEqual(InfoGatherer.permissionString(mode: 0o644), "rw-r--r--", "644")
        expectEqual(InfoGatherer.permissionString(mode: 0o000), "---------", "000")
        expectEqual(InfoGatherer.permissionString(mode: 0o700), "rwx------", "700")
    }

    await test("info(for:) reads a regular file") {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("fx-info-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("readme.txt")
        try "hi".write(to: file, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o644],
                                              ofItemAtPath: file.path)
        guard let info = InfoGatherer.info(for: file) else {
            return expect(false, "info gathered")
        }
        expectEqual(info.name, "readme.txt", "name")
        expect(!info.isDirectory, "not a directory")
        expectEqual(info.size, 2, "size in bytes")
        expectEqual(info.permissions, "rw-r--r--", "permissions string")
        expect(info.modified != nil, "has modified date")
        expect(info.symlinkTarget == nil, "not a symlink")
    }

    await test("info(for:) reports symlink targets and directories") {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("fx-info2-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let sub = dir.appendingPathComponent("sub")
        try FileManager.default.createDirectory(at: sub, withIntermediateDirectories: false)
        guard let dirInfo = InfoGatherer.info(for: sub) else {
            return expect(false, "directory info gathered")
        }
        expect(dirInfo.isDirectory, "directory flagged")
        expect(dirInfo.size == nil, "directory size deferred (nil)")

        let link = dir.appendingPathComponent("link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: sub)
        guard let linkInfo = InfoGatherer.info(for: link) else {
            return expect(false, "symlink info gathered")
        }
        expectEqual(linkInfo.symlinkTarget, sub.path, "symlink target path")
    }
}
