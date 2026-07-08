import Foundation
import FileExplorerCore

@MainActor
func macPlatformToolsTests() async {
    await test("ServerConnector normalizes supported server URLs") {
        let smb = ServerConnector.normalizedURL(from: "fileserver/Team")
        expectEqual(smb?.absoluteString, "smb://fileserver/Team",
                    "bare host/path gets smb scheme")
        let webdav = ServerConnector.normalizedURL(
            from: "WEBDAVS://example.com/share")
        expectEqual(webdav?.scheme, "webdavs", "scheme lowercased")
        expect(ServerConnector.normalizedURL(from: "http://example.com") == nil,
               "unsupported scheme rejected")
        expect(ServerConnector.normalizedURL(from: "smb:///share") == nil,
               "missing host rejected")
    }

    await test("PackageInspector recognizes common package extensions") {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let app = dir.appendingPathComponent("Tool.app")
        try FileManager.default.createDirectory(at: app,
                                                withIntermediateDirectories: false)
        expect(PackageInspector.isPackage(app), ".app directory is a package")
        let folder = dir.appendingPathComponent("Folder")
        try FileManager.default.createDirectory(at: folder,
                                                withIntermediateDirectories: false)
        expect(!PackageInspector.isPackage(folder),
               "ordinary folder is not package by fallback")
    }

    await test("DiskImagePlanner creates hdiutil commands") {
        let source = URL(fileURLWithPath: "/tmp/Project")
        let create = DiskImagePlanner.createCommand(sourceFolder: source)
        expectEqual(create.executable, "/usr/bin/hdiutil", "uses hdiutil")
        expectEqual(create.arguments,
                    ["create", "-volname", "Project", "-srcfolder",
                     "/tmp/Project", "/tmp/Project.dmg"],
                    "create command planned")
        expectEqual(DiskImagePlanner.attachCommand(
            image: URL(fileURLWithPath: "/tmp/a.dmg")).arguments,
                    ["attach", "/tmp/a.dmg"], "attach command planned")
        expectEqual(DiskImagePlanner.verifyCommand(
            image: URL(fileURLWithPath: "/tmp/a.dmg")).arguments,
                    ["verify", "/tmp/a.dmg"], "verify command planned")
    }

    await test("Finder alias files use alias naming and are not symlinks") {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let src = dir.appendingPathComponent("file.txt")
        try Data("x".utf8).write(to: src)

        let results = FileOperationService.makeAlias([src], kind: .bookmarkFile)
        guard case .success(let alias) = results[0].outcome else {
            expect(false, "bookmark alias should be created")
            return
        }
        expectEqual(alias.lastPathComponent, "file alias", "alias name")
        let values = try alias.resourceValues(forKeys: [.isSymbolicLinkKey])
        expect(values.isSymbolicLink != true, "bookmark alias is not a symlink")
    }
}
