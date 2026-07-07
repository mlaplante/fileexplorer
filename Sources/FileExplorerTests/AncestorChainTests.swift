import Foundation
import FileExplorerCore

@MainActor
func ancestorChainTests() async {
    await test("ancestorChain walks from root to the URL") {
        let url = URL(fileURLWithPath: "/Users/somebody/Documents")
        expectEqual(url.ancestorChain.map(\.path),
                    ["/", "/Users", "/Users/somebody", "/Users/somebody/Documents"],
                    "chain from root to leaf")
    }

    await test("ancestorChain of root is just root") {
        expectEqual(URL(fileURLWithPath: "/").ancestorChain.map(\.path), ["/"],
                    "root clamps immediately — no /.. runaway")
    }

    await test("ancestorChain standardizes its input") {
        let url = URL(fileURLWithPath: "/Users/somebody/./Documents/")
        expectEqual(url.ancestorChain.map(\.path),
                    ["/", "/Users", "/Users/somebody", "/Users/somebody/Documents"],
                    "dot components and trailing slash normalized")
    }
}
