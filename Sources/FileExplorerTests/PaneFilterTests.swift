import Foundation
import FileExplorerCore

@MainActor
func paneFilterTests() async {
    await test("PaneState filter narrows visibleEntries live") {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        try Data("img".utf8).write(to: dir.appendingPathComponent("a.png"))
        try Data("doc".utf8).write(to: dir.appendingPathComponent("b.txt"))
        try FileManager.default.createDirectory(
            at: dir.appendingPathComponent("sub"), withIntermediateDirectories: false)

        let pane = PaneState(url: dir)
        await pane.reload()
        expectEqual(pane.visibleEntries.count, 3, "unfiltered shows all")
        expectEqual(pane.totalCount, 3, "totalCount matches entries")

        pane.filter.preset = .images
        expectEqual(pane.visibleEntries.map(\.name), ["sub", "a.png"],
                    "images filter keeps folder + png, folders first")
        expectEqual(pane.totalCount, 3, "totalCount unaffected by filter")

        pane.filter = FilterState()
        expectEqual(pane.visibleEntries.count, 3, "clearing filter restores all")
    }

    await test("PaneState parses extension text into the filter") {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        try Data().write(to: dir.appendingPathComponent("a.png"))
        try Data().write(to: dir.appendingPathComponent("b.txt"))

        let pane = PaneState(url: dir)
        await pane.reload()

        pane.filterExtensionsText = " .PNG, jpg ,"
        expectEqual(pane.filter.extensions, ["png", "jpg"],
                    "text parsed: trimmed, lowercased, dots stripped, empties dropped")
        expectEqual(pane.visibleEntries.map(\.name), ["a.png"], "filter applied live")

        pane.clearFilters()
        expect(!pane.filter.isActive, "clearFilters deactivates")
        expectEqual(pane.filterExtensionsText, "", "clearFilters empties the draft text")
        expectEqual(pane.visibleEntries.count, 2, "all entries back")
    }

    await test("filter persists across reloads and navigation") {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        try Data().write(to: dir.appendingPathComponent("a.png"))
        try Data().write(to: dir.appendingPathComponent("b.txt"))

        let pane = PaneState(url: dir)
        await pane.reload()
        pane.filter.preset = .images
        await pane.reload()
        expectEqual(pane.visibleEntries.map(\.name), ["a.png"],
                    "filter still applied after reload")
    }
}
