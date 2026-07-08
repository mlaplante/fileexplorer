import Foundation
import FileExplorerCore

@MainActor
func archiveTests() async {
    await test("ArchiveKind detects supported archives") {
        expectEqual(ArchiveKind.detect("a.zip"), .zip, "zip")
        expectEqual(ArchiveKind.detect("A.ZIP"), .zip, "case-insensitive")
        expectEqual(ArchiveKind.detect("src.tar"), .tarball, "tar")
        expectEqual(ArchiveKind.detect("src.tar.gz"), .tarball, "tar.gz")
        expectEqual(ArchiveKind.detect("src.tgz"), .tarball, "tgz")
        expectEqual(ArchiveKind.detect("src.tar.bz2"), .tarball, "tar.bz2")
        expectEqual(ArchiveKind.detect("src.tar.xz"), .tarball, "tar.xz")
        expect(ArchiveKind.detect("photo.jpg") == nil, "jpg is not an archive")
        expect(ArchiveKind.detect("notes.gz") == nil,
               "bare .gz (not a tarball) is unsupported")
    }

    await test("ArchiveKind.stem strips the archive suffix") {
        expectEqual(ArchiveKind.stem("Photos.zip"), "Photos", "zip stem")
        expectEqual(ArchiveKind.stem("src.tar.gz"), "src", "tar.gz stem")
        expectEqual(ArchiveKind.stem("src.tgz"), "src", "tgz stem")
    }

    await test("Unarchiver round-trips a zip made by Zipper") {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("fx-archive-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let payload = dir.appendingPathComponent("hello.txt")
        try "hello".write(to: payload, atomically: true, encoding: .utf8)
        guard case .success(let archive) = Zipper.compress([payload], in: dir) else {
            return expect(false, "zip created")
        }
        guard case .success(let extracted) = Unarchiver.extract(archive) else {
            return expect(false, "extraction succeeds")
        }
        expectEqual(extracted.lastPathComponent, "Archive", "folder named after stem")
        let inner = extracted.appendingPathComponent("hello.txt")
        expectEqual(try String(contentsOf: inner, encoding: .utf8), "hello",
                    "payload round-trips")
        // A second extraction must not collide.
        guard case .success(let second) = Unarchiver.extract(archive) else {
            return expect(false, "second extraction succeeds")
        }
        expectEqual(second.lastPathComponent, "Archive 2", "collision-suffixed")
    }

    await test("Unarchiver extracts a tarball") {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("fx-tar-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        try "world".write(to: dir.appendingPathComponent("w.txt"),
                          atomically: true, encoding: .utf8)
        let tar = Process()
        tar.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
        tar.currentDirectoryURL = dir
        tar.arguments = ["-czf", "bundle.tar.gz", "w.txt"]
        try tar.run()
        tar.waitUntilExit()
        guard case .success(let extracted) =
            Unarchiver.extract(dir.appendingPathComponent("bundle.tar.gz")) else {
            return expect(false, "tar extraction succeeds")
        }
        expectEqual(extracted.lastPathComponent, "bundle", "stem folder")
        let inner = extracted.appendingPathComponent("w.txt")
        expectEqual(try String(contentsOf: inner, encoding: .utf8), "world",
                    "payload round-trips")
    }

    await test("Unarchiver reports corrupt archives and cleans up") {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("fx-corrupt-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let fake = dir.appendingPathComponent("broken.zip")
        try "not a zip".write(to: fake, atomically: true, encoding: .utf8)
        guard case .failure = Unarchiver.extract(fake) else {
            return expect(false, "corrupt zip fails")
        }
        expect(!FileManager.default.fileExists(
                   atPath: dir.appendingPathComponent("broken").path),
               "partial output folder removed")
    }
}
