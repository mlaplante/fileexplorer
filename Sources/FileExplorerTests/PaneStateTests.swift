import Foundation
import FileExplorerCore

@MainActor
func paneStateTests() async {
    await test("PaneState loads, navigates, and filters hidden files") {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let sub = dir.appendingPathComponent("sub")
        try FileManager.default.createDirectory(at: sub, withIntermediateDirectories: false)
        try Data().write(to: dir.appendingPathComponent("f.txt"))
        try Data().write(to: dir.appendingPathComponent(".hidden"))
        try Data().write(to: sub.appendingPathComponent("inner.txt"))

        let pane = PaneState(url: dir)
        await pane.reload()
        expectEqual(pane.entries.count, 2, "loads visible entries")
        expectEqual(pane.currentURL, dir.standardizedFileURL, "currentURL is start dir")

        pane.showHidden = true
        await pane.reload()
        expectEqual(pane.entries.count, 3, "showHidden reveals dotfile")

        await pane.navigate(to: sub)
        expectEqual(pane.currentURL, sub.standardizedFileURL, "navigated into sub")
        expectEqual(pane.entries.map(\.name), ["inner.txt"], "sub contents loaded")
        expect(pane.canGoBack, "history recorded")

        pane.selection.insert(sub.appendingPathComponent("inner.txt"))
        await pane.goBack()
        expectEqual(pane.currentURL, dir.standardizedFileURL, "back to start dir")
        expect(pane.selection.isEmpty, "selection cleared on navigation")

        await pane.goUp()
        expectEqual(pane.currentURL, dir.standardizedFileURL.deletingLastPathComponent(),
                    "goUp reaches parent")
    }

    await test("PaneState surfaces load errors") {
        let pane = PaneState(url: URL(fileURLWithPath: "/nonexistent-\(UUID().uuidString)"))
        await pane.reload()
        expect(pane.errorMessage != nil, "errorMessage set for unreadable dir")
        expect(pane.entries.isEmpty, "entries empty on error")
    }

    await test("PaneState sorts via sortOrder without recomputing per access") {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        try Data("xx".utf8).write(to: dir.appendingPathComponent("b.txt"))
        try Data("x".utf8).write(to: dir.appendingPathComponent("a.txt"))

        let pane = PaneState(url: dir)
        await pane.reload()
        expectEqual(pane.visibleEntries.map(\.name), ["a.txt", "b.txt"], "default name sort")

        pane.sortOrder = [KeyPathComparator(\FileEntry.size, order: .reverse)]
        expectEqual(pane.visibleEntries.map(\.name), ["b.txt", "a.txt"], "size sort applies")
    }

    await test("PaneState navigate to equivalent URL is a no-op for history") {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let pane = PaneState(url: dir)
        await pane.reload()
        // Same folder, unstandardized spelling (trailing "." component).
        await pane.navigate(to: dir.appendingPathComponent("."))
        expect(!pane.canGoBack, "equivalent URL does not pollute history")
    }
}
