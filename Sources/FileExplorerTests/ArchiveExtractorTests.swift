import Foundation
import FileExplorerCore

@MainActor
func archiveExtractorTests() async {
    func makeScratch(_ prefix: String) throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent(prefix + "-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    func run(_ executable: String, _ arguments: [String],
             cwd: URL? = nil) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.currentDirectoryURL = cwd
        try process.run()
        process.waitUntilExit()
        if process.terminationStatus != 0 {
            throw NSError(domain: "ArchiveExtractorTests", code: Int(process.terminationStatus))
        }
    }

    func makeFixtureArchives() throws -> (root: URL, archives: [URL], twoBytes: Data) {
        let root = try makeScratch("fx-archive-extractor")
        let payload = root.appendingPathComponent("payload")
        try FileManager.default.createDirectory(
            at: payload.appendingPathComponent("a/b"), withIntermediateDirectories: true)
        try "ONE".write(to: payload.appendingPathComponent("a/one.txt"),
                        atomically: true, encoding: .utf8)
        var bytes = Data()
        for index in 0..<1024 {
            bytes.append(UInt8(index % 251))
        }
        try bytes.write(to: payload.appendingPathComponent("a/b/two.bin"))
        try "TOP".write(to: payload.appendingPathComponent("top.txt"),
                        atomically: true, encoding: .utf8)

        let zip = root.appendingPathComponent("fixture.zip")
        try run("/usr/bin/ditto", ["-c", "-k", "--sequesterRsrc",
                                   payload.path, zip.path])
        let tar = root.appendingPathComponent("fixture.tar.gz")
        try run("/usr/bin/tar", ["-czf", tar.path, "."], cwd: payload)
        return (root, [zip, tar], bytes)
    }

    await test("ArchiveExtractor extracts selected files from zip and tar") {
        let fixture = try makeFixtureArchives()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        for archive in fixture.archives {
            let destination = try makeScratch("fx-archive-dest")
            defer { try? FileManager.default.removeItem(at: destination) }
            guard case .success = ArchiveExtractor.extract(
                entries: ["a/one.txt"], from: archive, into: destination) else {
                return expect(false, "single-entry extraction succeeds for \(archive.lastPathComponent)")
            }
            let extracted = destination.appendingPathComponent("a/one.txt")
            expectEqual(try String(contentsOf: extracted, encoding: .utf8), "ONE",
                        "single-entry bytes round-trip for \(archive.lastPathComponent)")
        }
    }

    await test("ArchiveExtractor extracts descendant file lists and avoids collisions") {
        let fixture = try makeFixtureArchives()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        for archive in fixture.archives {
            let destination = try makeScratch("fx-archive-dest")
            defer { try? FileManager.default.removeItem(at: destination) }
            try FileManager.default.createDirectory(
                at: destination.appendingPathComponent("a"), withIntermediateDirectories: true)
            guard case .success = ArchiveExtractor.extract(
                entries: ["a/one.txt", "a/b/two.bin"], from: archive, into: destination) else {
                return expect(false, "folder file-list extraction succeeds for \(archive.lastPathComponent)")
            }
            let moved = destination.appendingPathComponent("a 2/b/two.bin")
            expectEqual(try Data(contentsOf: moved), fixture.twoBytes,
                        "descendant bytes preserved under collision-suffixed top folder")
        }
    }

    await test("ArchiveExtractor preview extraction uses fresh temp folders") {
        let fixture = try makeFixtureArchives()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        for archive in fixture.archives {
            let tempRoot = try makeScratch("fx-archive-preview")
            defer { try? FileManager.default.removeItem(at: tempRoot) }
            let entry = ArchiveEntry(path: "a/one.txt", name: "one.txt",
                                     isDirectory: false, size: 3, modified: nil)
            guard case .success(let url) = ArchiveExtractor.extractForPreview(
                entry: entry, from: archive, tempRoot: tempRoot) else {
                return expect(false, "preview extraction succeeds for \(archive.lastPathComponent)")
            }
            expect(url.path.hasPrefix(tempRoot.path + "/"),
                   "preview URL is under temp root")
            let sessionDir = url.deletingLastPathComponent().deletingLastPathComponent()
            expectEqual(sessionDir.deletingLastPathComponent().standardizedFileURL.path,
                        tempRoot.standardizedFileURL.path,
                        "preview uses a fresh uuid directory")
            expectEqual(try String(contentsOf: url, encoding: .utf8), "ONE",
                        "preview bytes round-trip")
        }
    }

    await test("ArchiveExtractor rejects oversized previews before extraction") {
        let root = try makeScratch("fx-archive-big")
        defer { try? FileManager.default.removeItem(at: root) }
        let fake = root.appendingPathComponent("fake.zip")
        try "not used".write(to: fake, atomically: true, encoding: .utf8)
        let entry = ArchiveEntry(path: "huge.bin", name: "huge.bin",
                                 isDirectory: false,
                                 size: ArchiveExtractor.previewByteCap + 1,
                                 modified: nil)
        let result = ArchiveExtractor.extractForPreview(entry: entry, from: fake,
                                                        tempRoot: root)
        guard case .failure(let error) = result else {
            return expect(false, "oversized preview fails")
        }
        expect(error.message.contains("512 MB"), "failure mentions preview cap")
        expectEqual((try? FileManager.default.contentsOfDirectory(atPath: root.path).count), 1,
                    "no preview directory was created")
    }

    await test("ArchiveExtractor reports corrupt archive stderr") {
        let root = try makeScratch("fx-archive-corrupt")
        defer { try? FileManager.default.removeItem(at: root) }
        let corrupt = root.appendingPathComponent("broken.zip")
        try "garbage".write(to: corrupt, atomically: true, encoding: .utf8)
        let destination = root.appendingPathComponent("out")
        let result = ArchiveExtractor.extract(entries: ["a/one.txt"], from: corrupt,
                                              into: destination)
        guard case .failure(let error) = result else {
            return expect(false, "corrupt archive fails")
        }
        expect(error.message.contains("Extraction failed"), "failure carries stderr excerpt")
    }
}
