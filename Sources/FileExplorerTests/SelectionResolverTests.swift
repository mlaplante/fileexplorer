import Foundation
import FileExplorerCore

@MainActor
func selectionResolverTests() async {
    let u = (0...4).map { URL(fileURLWithPath: "/tmp/f\($0)") }

    await test("plain click replaces selection") {
        let next = SelectionResolver.resolve(
            clicked: u[2], in: u, current: [u[0], u[1]], baseline: [u[0], u[1]],
            anchor: u[0], commandDown: false, shiftDown: false)
        expectEqual(next, [u[2]], "plain click selects only the clicked item")
    }

    await test("command click toggles membership") {
        let added = SelectionResolver.resolve(
            clicked: u[3], in: u, current: [u[1]], baseline: [u[1]], anchor: u[1],
            commandDown: true, shiftDown: false)
        expectEqual(added, [u[1], u[3]], "cmd-click adds unselected item")

        let removed = SelectionResolver.resolve(
            clicked: u[1], in: u, current: [u[1], u[3]], baseline: [u[1], u[3]],
            anchor: u[1], commandDown: true, shiftDown: false)
        expectEqual(removed, [u[3]], "cmd-click removes selected item")
    }

    await test("shift click extends a contiguous range from the anchor") {
        let forward = SelectionResolver.resolve(
            clicked: u[3], in: u, current: [u[1]], baseline: [u[1]], anchor: u[1],
            commandDown: false, shiftDown: true)
        expectEqual(forward, [u[1], u[2], u[3]], "range extends forward")

        let backward = SelectionResolver.resolve(
            clicked: u[0], in: u, current: [u[2]], baseline: [u[2]], anchor: u[2],
            commandDown: false, shiftDown: true)
        expectEqual(backward, [u[0], u[1], u[2]], "range extends backward")

        let union = SelectionResolver.resolve(
            clicked: u[4], in: u, current: [u[0], u[3]], baseline: [u[0], u[3]],
            anchor: u[3], commandDown: false, shiftDown: true)
        expectEqual(union, [u[0], u[3], u[4]], "shift keeps prior selection (union)")
    }

    await test("shift without anchor or with stale anchor degrades to plain") {
        let noAnchor = SelectionResolver.resolve(
            clicked: u[2], in: u, current: [], baseline: [], anchor: nil,
            commandDown: false, shiftDown: true)
        expectEqual(noAnchor, [u[2]], "no anchor → clicked item only")

        let stale = SelectionResolver.resolve(
            clicked: u[2], in: u, current: [], baseline: [],
            anchor: URL(fileURLWithPath: "/tmp/gone"),
            commandDown: false, shiftDown: true)
        expectEqual(stale, [u[2]], "anchor not in list → clicked item only")
    }

    await test("shift-range shrinks back toward the anchor (pivot semantics)") {
        let pane = PaneState(url: URL(fileURLWithPath: "/tmp"))
        pane.entries = (0...5).map { i in
            FileEntry(url: URL(fileURLWithPath: "/t/f\(i)"), name: "f\(i)",
                      isDirectory: false, isHidden: false, isSymlink: false,
                      size: 0, created: nil, modified: .distantPast,
                      contentType: nil)
        }
        let u = pane.visibleEntries.map(\.url)

        pane.clickSelect(u[1], commandDown: false, shiftDown: false)
        pane.clickSelect(u[4], commandDown: false, shiftDown: true)
        expectEqual(pane.selection, Set(u[1...4]), "range grows to f4")
        pane.clickSelect(u[2], commandDown: false, shiftDown: true)
        expectEqual(pane.selection, Set(u[1...2]), "range SHRINKS back to f2")

        // cmd-click re-pivots: baseline becomes the toggled selection
        pane.clickSelect(u[5], commandDown: true, shiftDown: false)
        expectEqual(pane.selection, Set(u[1...2]).union([u[5]]), "cmd adds f5")
        pane.clickSelect(u[3], commandDown: false, shiftDown: true)
        expectEqual(pane.selection, Set(u[1...2]).union([u[5], u[3], u[4]]),
                    "shift from new anchor f5 ranges f3...f5 over the new pivot")
    }

    await test("shift-click with no anchor establishes one") {
        let pane = PaneState(url: URL(fileURLWithPath: "/tmp"))
        pane.entries = (0...3).map { i in
            FileEntry(url: URL(fileURLWithPath: "/t/g\(i)"), name: "g\(i)",
                      isDirectory: false, isHidden: false, isSymlink: false,
                      size: 0, created: nil, modified: .distantPast,
                      contentType: nil)
        }
        let u = pane.visibleEntries.map(\.url)
        pane.clickSelect(u[0], commandDown: false, shiftDown: true)
        expectEqual(pane.selection, [u[0]], "degrades to plain select")
        pane.clickSelect(u[2], commandDown: false, shiftDown: true)
        expectEqual(pane.selection, Set(u[0...2]), "second shift-click ranges")
    }

    await test("selected entries match standardized URL selections") {
        let entryURL = URL(fileURLWithPath: "/private/tmp/fx-selection/file.txt")
        let selectedURL = URL(fileURLWithPath: "/tmp/fx-selection/file.txt")
            .standardizedFileURL
        let entry = FileEntry(url: entryURL, name: "file.txt",
                              isDirectory: false, isHidden: false,
                              isSymlink: false, size: 0, created: nil,
                              modified: .distantPast, contentType: nil)

        let matches = SelectionResolver.entries(matching: [selectedURL],
                                                in: [entry])
        expectEqual(matches.map(\.url), [entryURL],
                    "standardized selection resolves matching visible entry")
    }
}
