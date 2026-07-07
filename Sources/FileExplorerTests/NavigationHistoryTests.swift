import Foundation
import FileExplorerCore

@MainActor
func navigationHistoryTests() async {
    let a = URL(fileURLWithPath: "/a")
    let b = URL(fileURLWithPath: "/b")
    let c = URL(fileURLWithPath: "/c")

    await test("navigate pushes history and clears forward") {
        var h = NavigationHistory(current: a)
        expect(!h.canGoBack && !h.canGoForward, "fresh history has no back/forward")
        h.navigate(to: b)
        expectEqual(h.current, b, "current is b")
        expect(h.canGoBack, "can go back after navigate")
        h.goBack()
        expectEqual(h.current, a, "back returns to a")
        expect(h.canGoForward, "can go forward after back")
        h.navigate(to: c)
        expect(!h.canGoForward, "navigate clears forward stack")
    }

    await test("back/forward round-trip") {
        var h = NavigationHistory(current: a)
        h.navigate(to: b)
        h.navigate(to: c)
        h.goBack()
        h.goBack()
        expectEqual(h.current, a, "two backs reach a")
        h.goForward()
        h.goForward()
        expectEqual(h.current, c, "two forwards reach c")
    }

    await test("no-ops are safe") {
        var h = NavigationHistory(current: a)
        h.goBack()
        h.goForward()
        expectEqual(h.current, a, "back/forward on empty stacks do nothing")
        h.navigate(to: a)
        expect(!h.canGoBack, "navigating to current URL is a no-op")
    }
}
