import Foundation
import FileExplorerCore

@MainActor
func directoryWatcherTests() async {
    await test("DirectoryWatcher fires on file creation (debounced)") {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let watcher = DirectoryWatcher()
        var fired = 0
        watcher.watch(dir) { fired += 1 }

        try Data().write(to: dir.appendingPathComponent("new1.txt"))
        try Data().write(to: dir.appendingPathComponent("new2.txt"))

        // Debounce is 200 ms; wait comfortably past it.
        try await Task.sleep(for: .milliseconds(600))
        expectEqual(fired, 1, "two rapid writes coalesce into one callback")

        try Data().write(to: dir.appendingPathComponent("new3.txt"))
        try await Task.sleep(for: .milliseconds(600))
        expectEqual(fired, 2, "later write fires again")

        watcher.stop()
        try Data().write(to: dir.appendingPathComponent("new4.txt"))
        try await Task.sleep(for: .milliseconds(600))
        expectEqual(fired, 2, "no callback after stop")
    }

    await test("DirectoryWatcher ignores unopenable paths") {
        let watcher = DirectoryWatcher()
        watcher.watch(URL(fileURLWithPath: "/nonexistent-\(UUID().uuidString)")) {
            expect(false, "must not fire for missing dir")
        }
        try await Task.sleep(for: .milliseconds(300))
        expect(true, "no crash watching a missing path")
        watcher.stop()
    }
}
