import Foundation
import FileExplorerCore

@MainActor
func usageScannerTests() async {
    await test("UsageScanner attributes nested bytes to immediate children") {
        let fm = FileManager.default
        let root = try makeTempDir()
        defer { try? fm.removeItem(at: root) }
        let a = root.appendingPathComponent("a")
        let deep = a.appendingPathComponent("deep")
        let b = root.appendingPathComponent("b")
        try fm.createDirectory(at: deep, withIntermediateDirectories: true)
        try Data(count: 100).write(to: deep.appendingPathComponent("file.bin"))
        try Data(count: 50).write(to: a.appendingPathComponent("x.bin"))
        try Data(count: 10).write(to: b)
        try Data(count: 5).write(to: root.appendingPathComponent("f.txt"))

        let scanner = UsageScanner()
        scanner.scan(root: root)
        await waitForUsageScanner(scanner)

        expectEqual(scanner.totalBytes, 165, "total bytes includes descendants")
        expectEqual(scanner.rows.map(\.name), ["a", "b", "f.txt"], "rows ordered by child size")
        expectEqual(scanner.rows[0].bytes, 150, "folder a receives nested file bytes")
        expectEqual(scanner.rows[0].itemCount, 2, "folder a counts descendant files")
        expectEqual(scanner.rows[1].bytes, 10, "root file b counted")
        expectEqual(scanner.rows[1].itemCount, 1, "root file item count is one")
        expectEqual(scanner.rows[2].bytes, 5, "root file with extension counted")
    }

    await test("UsageScanner includes hidden entries and does not follow symlinks") {
        let fm = FileManager.default
        let root = try makeTempDir()
        defer { try? fm.removeItem(at: root) }
        try Data(count: 33).write(to: root.appendingPathComponent(".hidden"))
        let target = root.appendingPathComponent("target.bin")
        try Data(count: 2048).write(to: target)
        try fm.createSymbolicLink(at: root.appendingPathComponent("link.bin"),
                                  withDestinationURL: target)

        let scanner = UsageScanner()
        scanner.scan(root: root)
        await waitForUsageScanner(scanner)

        expect(scanner.rows.contains { $0.name == ".hidden" && $0.bytes == 33 },
               "hidden file bytes counted")
        let linkBytes = scanner.rows.first { $0.name == "link.bin" }?.bytes ?? 0
        expect(linkBytes != 2048, "symlink does not attribute target bytes")
    }

    await test("UsageScanner skips unreadable subfolders and keeps siblings") {
        let fm = FileManager.default
        let root = try makeTempDir()
        defer { try? fm.removeItem(at: root) }
        let locked = root.appendingPathComponent("locked")
        try fm.createDirectory(at: locked, withIntermediateDirectories: false)
        try Data(count: 100).write(to: locked.appendingPathComponent("secret.bin"))
        try Data(count: 7).write(to: root.appendingPathComponent("sibling.bin"))
        try fm.setAttributes([.posixPermissions: 0], ofItemAtPath: locked.path)
        defer { try? fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: locked.path) }

        let scanner = UsageScanner()
        scanner.scan(root: root)
        await waitForUsageScanner(scanner)

        expectEqual(scanner.totalBytes, 7, "unreadable child bytes skipped")
        expect(scanner.rows.contains { $0.name == "sibling.bin" && $0.bytes == 7 },
               "readable sibling remains")
    }

    await test("UsageScanner scan generation keeps only latest root") {
        let fm = FileManager.default
        let first = try makeTempDir()
        let second = try makeTempDir()
        defer {
            try? fm.removeItem(at: first)
            try? fm.removeItem(at: second)
        }
        try Data(count: 100).write(to: first.appendingPathComponent("old.bin"))
        try Data(count: 9).write(to: second.appendingPathComponent("new.bin"))

        let scanner = UsageScanner()
        scanner.scan(root: first)
        scanner.scan(root: second)
        await waitForUsageScanner(scanner)

        expectEqual(scanner.totalBytes, 9, "second scan total wins")
        expectEqual(scanner.rows.map(\.name), ["new.bin"], "second scan rows win")
    }

    await test("UsageScanner cancel stops publication") {
        let fm = FileManager.default
        let root = try makeTempDir()
        defer { try? fm.removeItem(at: root) }
        let folder = root.appendingPathComponent("many")
        try fm.createDirectory(at: folder, withIntermediateDirectories: false)
        for index in 0..<4_000 {
            try Data(count: 1).write(to: folder.appendingPathComponent("\(index).bin"))
        }

        let scanner = UsageScanner()
        scanner.scan(root: root)
        await waitUntil { !scanner.rows.isEmpty || !scanner.isScanning }
        scanner.cancel()
        await waitUntil { !scanner.isScanning }
        let rows = scanner.rows
        await spinPollingLoop()
        expect(!scanner.isScanning, "cancel flips scanning off")
        expectEqual(scanner.rows, rows, "cancelled scan does not publish later rows")
    }

    await test("UsageScanner removal overlay survives terminal snapshot") {
        let fm = FileManager.default
        let root = try makeTempDir()
        defer { try? fm.removeItem(at: root) }
        let folder = root.appendingPathComponent("many")
        try fm.createDirectory(at: folder, withIntermediateDirectories: false)
        for index in 0..<4_000 {
            try Data(count: 1).write(to: folder.appendingPathComponent("\(index).bin"))
        }

        let scanner = UsageScanner()
        scanner.scan(root: root)
        await waitUntil { scanner.rows.contains { $0.url == folder.standardizedFileURL } }
        scanner.remove(url: folder, bytes: 4_000)
        await waitForUsageScanner(scanner)

        expect(!scanner.rows.contains { $0.url == folder.standardizedFileURL },
               "removed row stays removed after terminal snapshot")
        expectEqual(scanner.totalBytes, 0, "removed bytes stay subtracted after terminal snapshot")
    }

    await test("UsageScanner stale removal token is ignored after new generation") {
        let fm = FileManager.default
        let first = try makeTempDir()
        let second = try makeTempDir()
        defer {
            try? fm.removeItem(at: first)
            try? fm.removeItem(at: second)
        }
        let old = first.appendingPathComponent("old.bin")
        let new = second.appendingPathComponent("new.bin")
        try Data(count: 10).write(to: old)
        try Data(count: 20).write(to: new)

        let scanner = UsageScanner()
        scanner.scan(root: first)
        guard let token = scanner.removalToken() else {
            expect(false, "token available for active scan")
            return
        }
        scanner.scan(root: second)
        scanner.remove(url: old, bytes: 10, token: token)
        await waitForUsageScanner(scanner)

        expectEqual(scanner.totalBytes, 20, "stale removal did not affect new generation")
        expectEqual(scanner.rows.map(\.url), [new.standardizedFileURL],
                    "new generation rows remain intact")
    }

    await test("UsageScanner detached scan stops advancing after cancel") {
        let fm = FileManager.default
        let root = try makeTempDir()
        defer { try? fm.removeItem(at: root) }
        let folder = root.appendingPathComponent("many")
        try fm.createDirectory(at: folder, withIntermediateDirectories: false)
        for index in 0..<8_000 {
            try Data(count: 1).write(to: folder.appendingPathComponent("\(index).bin"))
        }

        let scanner = UsageScanner()
        scanner.scan(root: root)
        scanner.cancel()
        let visited = scanner.visitedEntryCount
        await spinPollingLoop()

        expectEqual(scanner.visitedEntryCount, visited,
                    "cancelled usage scan stops publishing visited count")
        expect(scanner.visitedEntryCount < 8_000, "cancelled before full synthetic tree")
    }

    await test("UsageScanner cap marks partial results") {
        let fm = FileManager.default
        let root = try makeTempDir()
        defer { try? fm.removeItem(at: root) }
        for index in 0..<50 {
            try Data(count: 1).write(to: root.appendingPathComponent("\(index).bin"))
        }

        let scanner = UsageScanner()
        scanner.scan(root: root, cap: 10)
        await waitForUsageScanner(scanner)

        expect(scanner.isPartial, "cap marks scan partial")
        expect(scanner.totalBytes <= 10, "partial scan stops at cap")
    }
}

@MainActor
private func waitForUsageScanner(_ scanner: UsageScanner) async {
    await waitUntil { !scanner.isScanning }
}

@MainActor
private func waitUntil(_ condition: @escaping @MainActor () -> Bool) async {
    let deadline = Date().addingTimeInterval(5)
    while !condition(), Date() < deadline {
        try? await Task.sleep(for: .milliseconds(10))
    }
}

private func spinPollingLoop() async {
    let deadline = Date().addingTimeInterval(0.1)
    while Date() < deadline {
        try? await Task.sleep(for: .milliseconds(10))
    }
}
