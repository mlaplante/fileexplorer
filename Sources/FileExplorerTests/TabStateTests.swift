import Foundation
import FileExplorerCore

@MainActor
func tabStateTests() async {
    let home = URL(fileURLWithPath: "/tmp")

    await test("TabState starts single-pane and toggles to dual") {
        let tab = TabState(url: home)
        expect(!tab.isDual, "starts single pane")
        expectEqual(tab.panes.count, 1, "one pane initially")
        expectEqual(tab.activePaneIndex, 0, "first pane active")

        tab.toggleDual()
        expect(tab.isDual, "dual after toggle")
        expectEqual(tab.panes.count, 2, "two panes")
        expectEqual(tab.activePaneIndex, 1, "new right pane becomes active")
        expectEqual(tab.panes[1].currentURL, tab.panes[0].currentURL,
                    "right pane clones left pane's folder")

        tab.toggleDual()
        expect(!tab.isDual, "single again after second toggle")
        expectEqual(tab.panes.count, 1, "back to one pane")
        expectEqual(tab.activePaneIndex, 0, "active index clamped back to 0")
    }

    await test("TabState activePane follows the index and clamps") {
        let tab = TabState(url: home)
        tab.toggleDual()
        tab.activePaneIndex = 0
        expect(tab.activePane === tab.panes[0], "activePane is left pane")
        tab.activePaneIndex = 1
        expect(tab.activePane === tab.panes[1], "activePane is right pane")
        tab.toggleDual()
        expect(tab.activePane === tab.panes[0], "activePane valid after collapse")
    }

    await test("TabState title tracks the active pane's folder") {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let sub = dir.appendingPathComponent("subfolder")
        try FileManager.default.createDirectory(at: sub, withIntermediateDirectories: false)

        let tab = TabState(url: dir)
        expectEqual(tab.title, dir.standardizedFileURL.lastPathComponent,
                    "title is folder name")
        await tab.activePane.navigate(to: sub)
        expectEqual(tab.title, "subfolder", "title follows navigation")
    }

    await test("PaneState startIfNeeded is idempotent") {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let pane = PaneState(url: dir)
        pane.startIfNeeded()
        pane.startIfNeeded()
        try await Task.sleep(for: .milliseconds(300))
        expect(pane.hasLoadedOnce, "startIfNeeded triggers an initial load")
    }
}
