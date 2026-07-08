import Foundation
import FileExplorerCore

@MainActor
func sessionPersisterTests() async {
    func makeTempDir() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("m7-persister-\(UUID().uuidString)")
    }

    await test("SessionPersister round-trips a session snapshot") {
        let dir = makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let persister = SessionPersister(directory: dir)

        expect(persister.loadSession() == nil, "no file yet → nil")

        let snapshot = SessionSnapshot(
            tabs: [SessionSnapshot.Tab(
                panes: [SessionSnapshot.Pane(path: "/tmp", showHidden: true)])],
            activeTabIndex: 0, recentFolders: ["/tmp"])
        persister.saveSession(snapshot)   // also creates the directory
        expectEqual(persister.loadSession(), snapshot,
                    "session survives save/load")
    }

    await test("SessionPersister tolerates corrupt session files") {
        let dir = makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(
            at: dir, withIntermediateDirectories: true)
        try Data("not json{{{".utf8).write(
            to: dir.appendingPathComponent("session.json"))
        let persister = SessionPersister(directory: dir)
        expect(persister.loadSession() == nil, "corrupt session → nil, no crash")
    }

    await test("AppSettings round-trips and defaults") {
        let dir = makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let persister = SessionPersister(directory: dir)

        expectEqual(persister.loadSettings(), AppSettings(),
                    "missing settings → defaults")
        expectEqual(AppSettings().jpegQuality, 0.85, "default JPEG quality")

        persister.saveSettings(AppSettings(jpegQuality: 0.6))
        expectEqual(persister.loadSettings().jpegQuality, 0.6,
                    "settings survive save/load")

        try Data("{}".utf8).write(to: dir.appendingPathComponent("settings.json"))
        expectEqual(persister.loadSettings(), AppSettings(),
                    "empty JSON object decodes to defaults (forward compat)")

        try Data("garbage".utf8).write(to: dir.appendingPathComponent("settings.json"))
        expectEqual(persister.loadSettings(), AppSettings(),
                    "corrupt settings → defaults, no crash")
    }
}
