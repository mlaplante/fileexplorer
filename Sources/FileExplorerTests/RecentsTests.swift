import Foundation
import FileExplorerCore

@MainActor
func recentsTests() async {
    await test("SessionState records navigations as MRU recents") {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let a = dir.appendingPathComponent("a")
        let b = dir.appendingPathComponent("b")
        try FileManager.default.createDirectory(at: a, withIntermediateDirectories: false)
        try FileManager.default.createDirectory(at: b, withIntermediateDirectories: false)

        let session = SessionState(url: dir)
        await session.activePane.navigate(to: a)
        await session.activePane.navigate(to: b)
        expectEqual(session.recentFolders.map(\.lastPathComponent), ["b", "a"],
                    "most recent first")

        await session.activePane.navigate(to: a)
        expectEqual(session.recentFolders.map(\.lastPathComponent), ["a", "b"],
                    "revisit moves to front without duplicate")
    }

    await test("recents recorded from new tabs and dual panes too") {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let sub = dir.appendingPathComponent("sub")
        try FileManager.default.createDirectory(at: sub, withIntermediateDirectories: false)

        let session = SessionState(url: dir)
        session.newTab()
        session.activeTab.toggleDual()
        await session.activePane.navigate(to: sub)
        expectEqual(session.recentFolders.first?.lastPathComponent, "sub",
                    "navigation in a dual pane of a new tab is recorded")
    }

    await test("recents are capped at 30") {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let session = SessionState(url: dir)
        for index in 0..<35 {
            let sub = dir.appendingPathComponent("d\(index)")
            try FileManager.default.createDirectory(at: sub, withIntermediateDirectories: false)
            await session.activePane.navigate(to: sub)
        }
        expectEqual(session.recentFolders.count, 30, "cap enforced")
        expectEqual(session.recentFolders.first?.lastPathComponent, "d34",
                    "newest kept")
    }
}
