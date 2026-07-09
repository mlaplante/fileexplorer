import Foundation
import FileExplorerCore

@MainActor
func scriptListerTests() async {
    func write(_ url: URL, mode: Int) throws {
        try "#!/bin/sh\nexit 0\n".write(to: url, atomically: true,
                                       encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: mode],
                                              ofItemAtPath: url.path)
    }

    await test("ScriptLister returns executable files sorted and filtered") {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let beta = dir.appendingPathComponent("beta.sh")
        let alpha = dir.appendingPathComponent("alpha.sh")
        let plain = dir.appendingPathComponent("plain.sh")
        let dotfile = dir.appendingPathComponent(".hidden.sh")
        let subdir = dir.appendingPathComponent("folder", isDirectory: true)

        try write(beta, mode: 0o755)
        try write(alpha, mode: 0o755)
        try write(plain, mode: 0o644)
        try write(dotfile, mode: 0o755)
        try FileManager.default.createDirectory(at: subdir,
                                                withIntermediateDirectories: false)
        try FileManager.default.setAttributes([.posixPermissions: 0o755],
                                              ofItemAtPath: subdir.path)

        expectEqual(ScriptLister.scripts(in: dir).map(\.lastPathComponent),
                    ["alpha.sh", "beta.sh"],
                    "only executable regular non-dot files are returned sorted")
    }

    await test("ScriptLister includes executable symlinks and skips broken symlinks") {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let target = dir.appendingPathComponent("target.sh")
        let link = dir.appendingPathComponent("linked.sh")
        let broken = dir.appendingPathComponent("broken.sh")

        try write(target, mode: 0o755)
        try FileManager.default.createSymbolicLink(at: link,
                                                   withDestinationURL: target)
        try FileManager.default.createSymbolicLink(
            at: broken,
            withDestinationURL: dir.appendingPathComponent("missing.sh"))

        expectEqual(ScriptLister.scripts(in: dir).map(\.lastPathComponent),
                    ["linked.sh", "target.sh"],
                    "valid executable symlink is included and broken symlink is skipped")
    }

    await test("ScriptLister returns empty for nonexistent and unreadable folders") {
        let dir = try makeTempDir()
        let missing = dir.appendingPathComponent("missing")
        expectEqual(ScriptLister.scripts(in: missing), [],
                    "missing folder returns empty")

        let unreadable = dir.appendingPathComponent("unreadable", isDirectory: true)
        try FileManager.default.createDirectory(at: unreadable,
                                                withIntermediateDirectories: false)
        try FileManager.default.setAttributes([.posixPermissions: 0o000],
                                              ofItemAtPath: unreadable.path)
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o755],
                                                  ofItemAtPath: unreadable.path)
            try? FileManager.default.removeItem(at: dir)
        }

        expectEqual(ScriptLister.scripts(in: unreadable), [],
                    "unreadable folder returns empty")
    }

    await test("ScriptLister exposes and creates scripts folder") {
        let defaultFolder = ScriptLister.defaultFolder
        expectEqual(defaultFolder.lastPathComponent, "Scripts",
                    "default folder ends in Scripts")
        expectEqual(defaultFolder.deletingLastPathComponent().lastPathComponent,
                    "FileExplorer",
                    "default folder lives under FileExplorer app support")

        let dir = try makeTempDir().appendingPathComponent(
            "Application Support/FileExplorer/Scripts", isDirectory: true)
        defer {
            try? FileManager.default.removeItem(
                at: dir.deletingLastPathComponent()
                    .deletingLastPathComponent()
                    .deletingLastPathComponent())
        }

        try ScriptLister.ensureFolderExists(dir)
        var isDirectory: ObjCBool = false
        expect(FileManager.default.fileExists(atPath: dir.path,
                                             isDirectory: &isDirectory),
               "ensureFolderExists creates the scripts folder")
        expect(isDirectory.boolValue, "created path is a directory")

        try ScriptLister.ensureFolderExists(dir)
        expect(FileManager.default.fileExists(atPath: dir.path,
                                             isDirectory: &isDirectory),
               "ensureFolderExists is idempotent")
    }
}
