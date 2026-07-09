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
        expect(await waitUntil { !model.isLoading }, "corrupt load finishes")
        expect(model.errorMessage?.isEmpty == false, "corrupt archive sets error")
        expectEqual(model.isPresented, false, "corrupt archive does not present")
        expectEqual(model.catalog == nil, true, "corrupt archive has no catalog")
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
}
