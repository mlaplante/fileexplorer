import Foundation
import FileExplorerCore

@MainActor
func archiveBrowserModelTests() async {
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
            throw NSError(domain: "ArchiveBrowserModelTests", code: Int(process.terminationStatus))
        }
    }

    func makeZipFixture() throws -> (root: URL, archive: URL) {
        let root = try makeScratch("fx-archive-model")
        let payload = root.appendingPathComponent("payload")
        try FileManager.default.createDirectory(
            at: payload.appendingPathComponent("a/b"), withIntermediateDirectories: true)
        try "ONE".write(to: payload.appendingPathComponent("a/one.txt"),
                        atomically: true, encoding: .utf8)
        try "TWO".write(to: payload.appendingPathComponent("a/b/two.txt"),
                        atomically: true, encoding: .utf8)
        try "TOP".write(to: payload.appendingPathComponent("top.txt"),
                        atomically: true, encoding: .utf8)
        let zip = root.appendingPathComponent("fixture.zip")
        try run("/usr/bin/ditto", ["-c", "-k", "--sequesterRsrc",
                                   payload.path, zip.path])
        return (root, zip)
    }

    func waitUntil(_ condition: @escaping @MainActor () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(50))
        }
        return condition()
    }

    await test("ArchiveBrowserModel opens zip catalog and navigates") {
        let fixture = try makeZipFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let model = ArchiveBrowserModel()
        model.open(archive: fixture.archive)
        expectEqual(model.isLoading, true, "open sets loading immediately")
        expectEqual(model.isPresented, true, "open presents loading sheet immediately")
        expect(await waitUntil { !model.isLoading }, "loading eventually finishes")
        expectEqual(model.isPresented, true, "successful open presents sheet")
        expectEqual(model.catalog?.children(of: "").map(\.path),
                    ["a", "top.txt"], "root children loaded")

        model.navigate(into: "a")
        expectEqual(model.currentPath, "a", "navigate enters folder")
        model.navigate(into: "a/b")
        expectEqual(model.currentPath, "a/b", "navigate enters nested folder")
        model.navigateUp()
        expectEqual(model.currentPath, "a", "navigateUp moves to parent")
        model.navigateUp()
        expectEqual(model.currentPath, "", "navigateUp reaches root")
        model.navigateUp()
        expectEqual(model.currentPath, "", "navigateUp clamps at root")
    }

    await test("ArchiveBrowserModel reports corrupt archives without presenting") {
        let root = try makeScratch("fx-archive-model-corrupt")
        defer { try? FileManager.default.removeItem(at: root) }
        let corrupt = root.appendingPathComponent("broken.zip")
        try "garbage".write(to: corrupt, atomically: true, encoding: .utf8)
        let model = ArchiveBrowserModel()
        model.open(archive: corrupt)
        expectEqual(model.isPresented, true, "corrupt archive starts in loading sheet")
        expect(await waitUntil { !model.isLoading }, "corrupt load finishes")
        expect(model.errorMessage?.isEmpty == false, "corrupt archive sets error")
        expectEqual(model.isPresented, false, "corrupt archive does not present")
        expectEqual(model.catalog == nil, true, "corrupt archive has no catalog")
    }

    await test("ArchiveBrowserModel exposes loading sheet during slow listing") {
        let model = ArchiveBrowserModel { _ in
            try? await Task.sleep(for: .milliseconds(250))
            return .success("-rw-r--r--  0 user group  1 Jul  9 10:30 one.txt")
        }
        model.open(archive: URL(fileURLWithPath: "/tmp/slow.zip"))
        expectEqual(model.isPresented, true, "slow listing presents immediately")
        expectEqual(model.isLoading, true, "slow listing remains loading")
        expect(await waitUntil { !model.isLoading }, "slow listing eventually finishes")
        expectEqual(model.catalog?.entry(at: "one.txt")?.name, "one.txt",
                    "slow listing loads catalog")
    }

    await test("ArchiveBrowserModel removes temp root on close and reopens fresh") {
        let fixture = try makeZipFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let model = ArchiveBrowserModel()
        model.open(archive: fixture.archive)
        expect(await waitUntil { !model.isLoading }, "first load finishes")
        let temp = model.previewTempRoot()
        expect(FileManager.default.fileExists(atPath: temp.path), "temp root created")
        model.close()
        expect(!FileManager.default.fileExists(atPath: temp.path), "close removes temp root")
        expectEqual(model.catalog == nil, true, "close clears catalog")
        expectEqual(model.archiveURL, nil, "close clears archive URL")

        model.open(archive: fixture.archive)
        expect(await waitUntil { !model.isLoading }, "second load finishes")
        let second = model.previewTempRoot()
        expect(second.path != temp.path, "reopen creates a fresh temp root")
    }

    await test("ArchiveBrowserModel stale preview extraction cleans up after close") {
        let fixture = try makeZipFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let model = ArchiveBrowserModel()
        model.open(archive: fixture.archive)
        expect(await waitUntil { !model.isLoading }, "load finishes")
        let archive = fixture.archive
        let token = model.presentationToken
        let tempRoot = model.previewTempRoot()
        let entry = ArchiveEntry(path: "a/one.txt", name: "one.txt",
                                 isDirectory: false, size: 3, modified: nil)
        let task = Task {
            try? await Task.sleep(for: .milliseconds(150))
            return ArchiveExtractor.extractForPreview(entry: entry, from: archive,
                                                      tempRoot: tempRoot)
        }
        model.close()
        let result = await task.value
        if case .success(let url) = result,
           !model.isCurrentPreviewContext(archive: archive, token: token) {
            model.discardPreviewExtraction(at: url)
        }
        expect(await waitUntil {
            !FileManager.default.fileExists(atPath: tempRoot.path)
        }, "stale preview temp root remains deleted")
    }
}
