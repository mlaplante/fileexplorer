import Foundation
import FileExplorerCore

@MainActor
func selectionResolverTests() async {
    let u = (0...4).map { URL(fileURLWithPath: "/tmp/f\($0)") }

    await test("plain click replaces selection") {
        let next = SelectionResolver.resolve(
            clicked: u[2], in: u, current: [u[0], u[1]], anchor: u[0],
            commandDown: false, shiftDown: false)
        expectEqual(next, [u[2]], "plain click selects only the clicked item")
    }

    await test("command click toggles membership") {
        let added = SelectionResolver.resolve(
            clicked: u[3], in: u, current: [u[1]], anchor: u[1],
            commandDown: true, shiftDown: false)
        expectEqual(added, [u[1], u[3]], "cmd-click adds unselected item")

        let removed = SelectionResolver.resolve(
            clicked: u[1], in: u, current: [u[1], u[3]], anchor: u[1],
            commandDown: true, shiftDown: false)
        expectEqual(removed, [u[3]], "cmd-click removes selected item")
    }

    await test("shift click extends a contiguous range from the anchor") {
        let forward = SelectionResolver.resolve(
            clicked: u[3], in: u, current: [u[1]], anchor: u[1],
            commandDown: false, shiftDown: true)
        expectEqual(forward, [u[1], u[2], u[3]], "range extends forward")

        let backward = SelectionResolver.resolve(
            clicked: u[0], in: u, current: [u[2]], anchor: u[2],
            commandDown: false, shiftDown: true)
        expectEqual(backward, [u[0], u[1], u[2]], "range extends backward")

        let union = SelectionResolver.resolve(
            clicked: u[4], in: u, current: [u[0], u[3]], anchor: u[3],
            commandDown: false, shiftDown: true)
        expectEqual(union, [u[0], u[3], u[4]], "shift keeps prior selection (union)")
    }

    await test("shift without anchor or with stale anchor degrades to plain") {
        let noAnchor = SelectionResolver.resolve(
            clicked: u[2], in: u, current: [], anchor: nil,
            commandDown: false, shiftDown: true)
        expectEqual(noAnchor, [u[2]], "no anchor → clicked item only")

        let stale = SelectionResolver.resolve(
            clicked: u[2], in: u, current: [],
            anchor: URL(fileURLWithPath: "/tmp/gone"),
            commandDown: false, shiftDown: true)
        expectEqual(stale, [u[2]], "anchor not in list → clicked item only")
    }
}
