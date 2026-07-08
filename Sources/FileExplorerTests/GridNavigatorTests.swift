import CoreGraphics
import Foundation
import FileExplorerCore

@MainActor
func gridNavigatorTests() async {
    await test("GridNavigator moves through regular and ragged rows") {
        let urls = (0..<7).map { URL(fileURLWithPath: "/tmp/item\($0)") }
        let frames: [URL: CGRect] = [
            urls[0]: CGRect(x: 0, y: 0, width: 100, height: 100),
            urls[1]: CGRect(x: 120, y: 0, width: 100, height: 100),
            urls[2]: CGRect(x: 240, y: 0, width: 100, height: 100),
            urls[3]: CGRect(x: 0, y: 120, width: 100, height: 100),
            urls[4]: CGRect(x: 120, y: 120, width: 100, height: 100),
            urls[5]: CGRect(x: 240, y: 120, width: 100, height: 100),
            urls[6]: CGRect(x: 0, y: 240, width: 100, height: 100),
        ]

        expectEqual(GridNavigator.target(from: urls[0], direction: .right,
                                         frames: frames),
                    urls[1], "right moves within row")
        expectEqual(GridNavigator.target(from: urls[1], direction: .down,
                                         frames: frames),
                    urls[4], "down keeps column in regular row")
        expectEqual(GridNavigator.target(from: urls[4], direction: .down,
                                         frames: frames),
                    urls[6], "down into ragged row picks nearest x")
        expectEqual(GridNavigator.target(from: urls[6], direction: .down,
                                         frames: frames),
                    nil, "down from last row does not wrap")
        expectEqual(GridNavigator.target(from: urls[0], direction: .left,
                                         frames: frames),
                    nil, "left at first column does not wrap")
        expectEqual(GridNavigator.target(from: nil, direction: .right,
                                         frames: frames),
                    urls[0], "empty current selects top-left")
    }
}
