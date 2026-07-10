import Foundation
import FileExplorerCore

@MainActor
func springLoadTests() async {
    await test("SpringLoad timing threshold matches Finder-style delay") {
        let start = Date(timeIntervalSince1970: 100)
        expectEqual(SpringLoad.delay, 0.7, "default delay")
        expect(!SpringLoad.shouldSpring(
            hoverStart: start,
            now: start.addingTimeInterval(0.69),
            delay: 0.7), "does not spring before delay")
        expect(SpringLoad.shouldSpring(
            hoverStart: start,
            now: start.addingTimeInterval(0.7),
            delay: 0.7), "springs at delay")
        expect(SpringLoad.shouldSpring(
            hoverStart: start,
            now: start.addingTimeInterval(0.8),
            delay: 0.7), "springs after delay")
    }

    await test("SpringLoadModel fires after injected delay") {
        let timer = ManualTimer()
        let folder = URL(fileURLWithPath: "/tmp/a")
        var sprung: URL?
        let model = SpringLoadModel(delay: .milliseconds(50),
                                    onSpring: { url in sprung = url },
                                    sleeper: { await timer.sleep($0) })
        model.beginHover(folder: folder)
        await settle { timer.pendingCount == 1 }
        timer.fireAll()
        await settle { sprung != nil }
        expectEqual(sprung, folder, "callback fired with folder")
    }

    await test("SpringLoadModel cancel prevents spring") {
        let timer = ManualTimer()
        let folder = URL(fileURLWithPath: "/tmp/a")
        var sprung: URL?
        let model = SpringLoadModel(delay: .milliseconds(50),
                                    onSpring: { url in sprung = url },
                                    sleeper: { await timer.sleep($0) })
        model.beginHover(folder: folder)
        await settle { timer.pendingCount == 1 }
        model.endHover()
        timer.fireAll()
        await drainMainQueue()
        expect(sprung == nil, "cancelled hover did not fire")
    }

    await test("SpringLoadModel retarget resets clock") {
        let timer = ManualTimer()
        let first = URL(fileURLWithPath: "/tmp/a")
        let second = URL(fileURLWithPath: "/tmp/b")
        var fired: [URL] = []
        let model = SpringLoadModel(delay: .milliseconds(50),
                                    onSpring: { url in fired.append(url) },
                                    sleeper: { await timer.sleep($0) })
        model.beginHover(folder: first)
        await settle { timer.pendingCount == 1 }
        model.beginHover(folder: second)
        await settle { timer.pendingCount == 2 }
        timer.fireFirst()   // release the superseded first timer
        await drainMainQueue()
        expect(fired.isEmpty, "first timer was reset")
        timer.fireAll()
        await settle { !fired.isEmpty }
        expectEqual(fired, [second], "only retargeted folder fires")
    }
}
