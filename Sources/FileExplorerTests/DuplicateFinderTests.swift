import Foundation
import FileExplorerCore

@MainActor
func duplicateFinderTests() async {
    await test("DuplicateFinder groups identical files and sorts members newest first") {
        let fm = FileManager.default
        let root = try makeTempDir()
        defer { try? fm.removeItem(at: root) }
        let leftDir = root.appendingPathComponent("left")
        let rightDir = root.appendingPathComponent("right")
        try fm.createDirectory(at: leftDir, withIntermediateDirectories: false)
        try fm.createDirectory(at: rightDir, withIntermediateDirectories: false)
        let old = leftDir.appendingPathComponent("copy.bin")
        let new = rightDir.appendingPathComponent("copy.bin")
        try Data(repeating: 7, count: 1024).write(to: old)
        try Data(repeating: 7, count: 1024).write(to: new)
        try setModified(old, 10)
        try setModified(new, 20)

        let finder = DuplicateFinder()
        finder.scan(root: root)
        await waitForDuplicateFinder(finder)

        expectEqual(finder.groups.count, 1, "one duplicate group found")
        expectEqual(finder.groups.first?.size, 1024, "group size matches file size")
        expectEqual(finder.groups.first?.members.map(\.url), [new, old],
                    "members sorted newest first")
    }

    await test("DuplicateFinder ignores same-size different bytes") {
        let fm = FileManager.default
        let root = try makeTempDir()
        defer { try? fm.removeItem(at: root) }
        try Data("aa".utf8).write(to: root.appendingPathComponent("a.txt"))
        try Data("bb".utf8).write(to: root.appendingPathComponent("b.txt"))

        let finder = DuplicateFinder()
        finder.scan(root: root)
        await waitForDuplicateFinder(finder)

        expect(finder.groups.isEmpty, "same-size different content not grouped")
    }

    await test("DuplicateFinder skips zero-byte files and symlinks") {
        let fm = FileManager.default
        let root = try makeTempDir()
        defer { try? fm.removeItem(at: root) }
        let emptyA = root.appendingPathComponent("empty-a")
        let emptyB = root.appendingPathComponent("empty-b")
        let real = root.appendingPathComponent("real.bin")
        try Data().write(to: emptyA)
        try Data().write(to: emptyB)
        try Data(repeating: 3, count: 8).write(to: real)
        try fm.createSymbolicLink(at: root.appendingPathComponent("real-link.bin"),
                                  withDestinationURL: real)

        let finder = DuplicateFinder()
        finder.scan(root: root)
        await waitForDuplicateFinder(finder)

        expect(finder.groups.isEmpty, "zero-byte files and symlinks do not form groups")
    }

    await test("DuplicateFinder sorts groups by wasted bytes") {
        let fm = FileManager.default
        let root = try makeTempDir()
        defer { try? fm.removeItem(at: root) }
        try writeDuplicateSet(root: root, stem: "big", count: 2, size: 30, byte: 1)
        try writeDuplicateSet(root: root, stem: "small-many", count: 4, size: 10, byte: 2)
        try writeDuplicateSet(root: root, stem: "small-two", count: 2, size: 20, byte: 3)

        let finder = DuplicateFinder()
        finder.scan(root: root)
        await waitForDuplicateFinder(finder)

        expectEqual(finder.groups.map(\.wastedBytes), [30, 30, 20],
                    "groups sorted by wasted bytes descending")
    }

    await test("DuplicateFinder drops unreadable hash failures silently") {
        let fm = FileManager.default
        let root = try makeTempDir()
        defer { try? fm.removeItem(at: root) }
        let readable = root.appendingPathComponent("readable.bin")
        let locked = root.appendingPathComponent("locked.bin")
        try Data(repeating: 9, count: 16).write(to: readable)
        try Data(repeating: 9, count: 16).write(to: locked)
        try fm.setAttributes([.posixPermissions: 0], ofItemAtPath: locked.path)
        defer { try? fm.setAttributes([.posixPermissions: 0o644], ofItemAtPath: locked.path) }

        let finder = DuplicateFinder()
        finder.scan(root: root)
        await waitForDuplicateFinder(finder)

        expect(finder.groups.isEmpty, "unreadable file is dropped, leaving no duplicate")
    }

    await test("DuplicateFinder cancel and second scan supersede prior work") {
        let fm = FileManager.default
        let first = try makeTempDir()
        let second = try makeTempDir()
        defer {
            try? fm.removeItem(at: first)
            try? fm.removeItem(at: second)
        }
        try writeDuplicateSet(root: first, stem: "old", count: 300, size: 32, byte: 4)
        try writeDuplicateSet(root: second, stem: "new", count: 2, size: 12, byte: 5)

        let finder = DuplicateFinder()
        finder.scan(root: first)
        await waitUntilDuplicate { finder.scannedFileCount > 0 || !finder.isScanning }
        finder.cancel()
        await waitUntilDuplicate { !finder.isScanning }
        expect(!finder.isScanning, "cancel flips scanning off")

        finder.scan(root: first)
        finder.scan(root: second)
        await waitForDuplicateFinder(finder)
        expectEqual(finder.groups.count, 1, "second scan result wins")
        expectEqual(finder.groups.first?.size, 12, "second scan group is published")
    }

    await test("DuplicateFinder detached scan stops advancing after cancel") {
        let fm = FileManager.default
        let root = try makeTempDir()
        defer { try? fm.removeItem(at: root) }
        for index in 0..<8_000 {
            try Data(repeating: UInt8(index % 251), count: 8)
                .write(to: root.appendingPathComponent("\(index).bin"))
        }

        let finder = DuplicateFinder()
        finder.scan(root: root)
        finder.cancel()
        let scanned = finder.scannedFileCount
        await waitUntilDuplicate {
            finder.scannedFileCount != scanned || !finder.isScanning
        }

        expectEqual(finder.scannedFileCount, scanned,
                    "cancelled duplicate scan stops publishing scanned count")
        expect(finder.scannedFileCount < 8_000, "cancelled before full synthetic tree")
    }

    await test("DuplicateFinder cap marks partial results") {
        let fm = FileManager.default
        let root = try makeTempDir()
        defer { try? fm.removeItem(at: root) }
        for index in 0..<50 {
            try Data(repeating: UInt8(index), count: 4)
                .write(to: root.appendingPathComponent("\(index).bin"))
        }

        let finder = DuplicateFinder()
        finder.scan(root: root, cap: 10)
        await waitForDuplicateFinder(finder)

        expect(finder.isPartial, "cap marks duplicate scan partial")
        expectEqual(finder.scannedFileCount, 10, "scan stops at file cap")
    }

    await test("same-size files with identical prefix but different tail are not duplicates") {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("dupes-prefix-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        var content = Data(repeating: 0xCD, count: 256 * 1024)
        try content.write(to: dir.appendingPathComponent("one.bin"))
        content[content.count - 1] ^= 0xFF
        try content.write(to: dir.appendingPathComponent("two.bin"))
        try content.write(to: dir.appendingPathComponent("three.bin"))

        let finder = DuplicateFinder()
        finder.scan(root: dir)
        while finder.isScanning { try await Task.sleep(for: .milliseconds(5)) }

        expectEqual(finder.groups.count, 1, "only the true pair groups")
        expectEqual(finder.groups.first?.members.count, 2,
                    "two/three group; one is excluded despite matching prefix")
    }
}

private func writeDuplicateSet(root: URL, stem: String, count: Int,
                               size: Int, byte: UInt8) throws {
    for index in 0..<count {
        try Data(repeating: byte, count: size)
            .write(to: root.appendingPathComponent("\(stem)-\(index).bin"))
        try setModified(root.appendingPathComponent("\(stem)-\(index).bin"),
                        TimeInterval(index))
    }
}

private func setModified(_ url: URL, _ timestamp: TimeInterval) throws {
    try FileManager.default.setAttributes(
        [.modificationDate: Date(timeIntervalSince1970: timestamp)],
        ofItemAtPath: url.path)
}

@MainActor
private func waitForDuplicateFinder(_ finder: DuplicateFinder) async {
    await waitUntilDuplicate { !finder.isScanning }
}

@MainActor
private func waitUntilDuplicate(_ condition: @escaping @MainActor () -> Bool) async {
    let deadline = Date().addingTimeInterval(8)
    while !condition(), Date() < deadline {
        try? await Task.sleep(for: .milliseconds(10))
    }
}
