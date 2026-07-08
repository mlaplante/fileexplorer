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
        let folder = URL(fileURLWithPath: "/tmp/a")
        var sprung: URL?
        let model = SpringLoadModel(delay: .milliseconds(50)) { url in
            sprung = url
        }
        model.beginHover(folder: folder)
        try await Task.sleep(for: .milliseconds(80))
        expectEqual(sprung, folder, "callback fired with folder")
    }

    await test("SpringLoadModel cancel prevents spring") {
        let folder = URL(fileURLWithPath: "/tmp/a")
        var sprung: URL?
        let model = SpringLoadModel(delay: .milliseconds(50)) { url in
            sprung = url
        }
        model.beginHover(folder: folder)
        model.endHover()
        try await Task.sleep(for: .milliseconds(80))
        expect(sprung == nil, "cancelled hover did not fire")
    }

    await test("SpringLoadModel retarget resets clock") {
        let first = URL(fileURLWithPath: "/tmp/a")
        let second = URL(fileURLWithPath: "/tmp/b")
        var fired: [URL] = []
        let model = SpringLoadModel(delay: .milliseconds(50)) { url in
            fired.append(url)
        }
        model.beginHover(folder: first)
        try await Task.sleep(for: .milliseconds(30))
        model.beginHover(folder: second)
        try await Task.sleep(for: .milliseconds(30))
        expect(fired.isEmpty, "first timer was reset")
        try await Task.sleep(for: .milliseconds(35))
        expectEqual(fired, [second], "only retargeted folder fires")
    }
}
