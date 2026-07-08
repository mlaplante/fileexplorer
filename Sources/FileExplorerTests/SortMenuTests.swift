import Foundation
import FileExplorerCore

@MainActor
func sortMenuTests() async {
    await test("SortMenu recovers axis and direction from pane sort order") {
        let pane = PaneState(url: URL(fileURLWithPath: "/tmp"))
        let state = SortMenu.state(of: pane.sortOrder)

        expectEqual(state.axis, .name, "default pane sort is name")
        expect(state.ascending, "default pane sort is ascending")
    }

    await test("SortMenu comparators round-trip through SortTokenCoder") {
        let comparators = SortMenu.comparators(for: .size, ascending: false)
        let tokens = SortTokenCoder.tokens(from: comparators)
        let restored = SortTokenCoder.comparators(from: tokens)

        expectEqual(tokens, [SortToken(field: .size, ascending: false)],
                    "size descending encodes")
        expectEqual(SortTokenCoder.tokens(from: restored), tokens,
                    "decoded comparator re-encodes equally")
    }

    await test("SortMenu toggles active axis and resets new axis ascending") {
        let current = SortMenu.comparators(for: .kind, ascending: true)
        let flipped = SortMenu.toggledOrder(current: current, selecting: .kind)
        let changed = SortMenu.toggledOrder(current: current, selecting: .dateModified)

        expectEqual(SortMenu.state(of: flipped).axis, .kind, "same axis preserved")
        expect(!SortMenu.state(of: flipped).ascending, "same axis reverses")
        expectEqual(SortMenu.state(of: changed).axis, .dateModified,
                    "new axis selected")
        expect(SortMenu.state(of: changed).ascending, "new axis starts ascending")
    }
}
