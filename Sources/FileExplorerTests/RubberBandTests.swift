import Foundation
import FileExplorerCore

@MainActor
func rubberBandTests() async {
    let a = URL(fileURLWithPath: "/tmp/a")
    let b = URL(fileURLWithPath: "/tmp/b")
    let c = URL(fileURLWithPath: "/tmp/c")
    let frames = [
        a: CGRect(x: 0, y: 0, width: 100, height: 100),
        b: CGRect(x: 200, y: 0, width: 100, height: 100),
        c: CGRect(x: 0, y: 200, width: 100, height: 100),
    ]

    await test("normalizedRect handles any drag direction") {
        let rect = RubberBand.normalizedRect(from: CGPoint(x: 250, y: 250),
                                             to: CGPoint(x: 50, y: 50))
        expectEqual(rect, CGRect(x: 50, y: 50, width: 200, height: 200),
                    "up-left drag normalizes")
    }

    await test("select replaces with intersecting cells") {
        let rect = CGRect(x: 50, y: 50, width: 200, height: 200)
        expectEqual(RubberBand.select(frames: frames, rect: rect,
                                      base: [c], union: false),
                    [a, b, c], "all three intersect; base ignored on replace")
        let narrow = CGRect(x: 0, y: 0, width: 50, height: 50)
        expectEqual(RubberBand.select(frames: frames, rect: narrow,
                                      base: [b], union: false),
                    [a], "only a intersects")
    }

    await test("union mode keeps the pre-drag base selection") {
        let narrow = CGRect(x: 0, y: 0, width: 50, height: 50)
        expectEqual(RubberBand.select(frames: frames, rect: narrow,
                                      base: [b], union: true),
                    [a, b], "base unioned")
    }
}
