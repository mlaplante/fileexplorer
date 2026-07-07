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
        expect(!pane.hasLoadedOnce, "hasLoadedOnce starts false")
        await pane.reload()
        expect(pane.hasLoadedOnce, "hasLoadedOnce set after first reload")
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

    await test("PaneState last reload wins under overlap") {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        try Data().write(to: dir.appendingPathComponent("v.txt"))
        try Data().write(to: dir.appendingPathComponent(".h"))

        let pane = PaneState(url: dir)
        // Overlapping reloads: fire one without awaiting, then start a
        // second (awaited) one with a different showHidden. `Task { }` only
        // enqueues -- it doesn't run until this (MainActor) task suspends --
        // so without a yield, `earlier`'s body wouldn't even read
        // `showHidden` until after we'd already flipped it below, making the
        // two loads indistinguishable and the test pass trivially either
        // way. The explicit `Task.yield()` lets `earlier`'s prefix
        // (reloadID bump + showHidden read) run first, while showHidden is
        // still false, so it captures the *lower* reloadID and a stale
        // (hidden-excluded) snapshot -- genuinely racing the final reload
        // below rather than duplicating it.
        pane.showHidden = false
        let earlier = Task { await pane.reload() }
        await Task.yield()
        pane.showHidden = true
        await pane.reload()
        _ = await earlier.value
        expectEqual(pane.entries.count, 2,
                    "state reflects the most recent reload request, not whichever finishes last")
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
        pane.selection.insert(dir.appendingPathComponent("anything"))
        // Same folder, unstandardized spelling (trailing "." component).
        await pane.navigate(to: dir.appendingPathComponent("."))
        expect(!pane.canGoBack, "equivalent URL does not pollute history")
        expect(!pane.selection.isEmpty, "selection preserved on same-URL navigate")
    }
}
