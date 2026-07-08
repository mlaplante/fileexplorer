import Foundation
import FileExplorerCore

@MainActor
func advancedSystemTests() async {
    await test("PermissionTools plans chmod chown flags and quarantine commands") {
        let url = URL(fileURLWithPath: "/tmp/file.txt")
        expectEqual(PermissionTools.chmodPlan(
            url: url, octalMode: "644", recursive: false)?.arguments,
                    ["chmod", "644", "/tmp/file.txt"],
                    "chmod planned")
        expectEqual(PermissionTools.chmodPlan(
            url: url, octalMode: "bad", recursive: false),
                    nil, "invalid octal rejected")
        expectEqual(PermissionTools.chownPlan(
            url: url, owner: "501", group: "20", recursive: true)?.arguments,
                    ["chown", "-R", "501:20", "/tmp/file.txt"],
                    "chown recursive planned")
        expectEqual(PermissionTools.lockedPlan(
            url: url, locked: true, recursive: false).arguments,
                    ["chflags", "uchg", "/tmp/file.txt"],
                    "lock planned")
        expectEqual(PermissionTools.quarantinePlan(
            url: url, quarantined: false, recursive: true).arguments,
                    ["xattr", "-r", "-d", "com.apple.quarantine",
                     "/tmp/file.txt"],
                    "clear quarantine recursive planned")
    }

    await test("CloudFileTools classifies cloud states from resource values") {
        expectEqual(CloudFileTools.state(from: CloudFileResourceValues(
            isUbiquitous: false)), .notCloud, "local file")
        expectEqual(CloudFileTools.state(from: CloudFileResourceValues(
            isUbiquitous: true, isDownloaded: true)), .downloaded,
                    "downloaded cloud file")
        expectEqual(CloudFileTools.state(from: CloudFileResourceValues(
            isUbiquitous: true, isDownloaded: false)), .evicted,
                    "evicted cloud file")
        expectEqual(CloudFileTools.state(from: CloudFileResourceValues(
            isUbiquitous: true, isDownloading: true)), .downloading,
                    "download in progress")
        expectEqual(CloudFileTools.state(from: CloudFileResourceValues(
            isUbiquitous: true, hasUnresolvedConflicts: true)), .conflicted,
                    "conflict takes precedence")
    }

    await test("AdvancedDiffEngine ignores patterns and uses checksum mode") {
        let root = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let left = root.appendingPathComponent("left")
        let right = root.appendingPathComponent("right")
        try FileManager.default.createDirectory(at: left,
                                                withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: right,
                                                withIntermediateDirectories: true)
        try Data("same".utf8).write(to: left.appendingPathComponent("a.txt"))
        try Data("same".utf8).write(to: right.appendingPathComponent("a.txt"))
        try Data("left".utf8).write(to: left.appendingPathComponent("b.tmp"))
        try Data("right".utf8).write(to: right.appendingPathComponent("b.tmp"))
        try Data("aa".utf8).write(to: left.appendingPathComponent("same-size.txt"))
        try Data("bb".utf8).write(to: right.appendingPathComponent("same-size.txt"))

        let ignored = AdvancedDiffEngine.compare(
            left: left,
            right: right,
            options: AdvancedDiffOptions(ignoredPatterns: ["*.tmp"]))
        expect(!ignored.map(\.relativePath).contains("b.tmp"),
               "wildcard ignored")
        let plain = ignored.first { $0.relativePath == "same-size.txt" }
        expectEqual(plain?.kind, .same, "same size/mtime tolerance appears same")

        let checksum = AdvancedDiffEngine.compare(
            left: left,
            right: right,
            options: AdvancedDiffOptions(ignoredPatterns: ["*.tmp"],
                                         useChecksum: true))
        let changed = checksum.first { $0.relativePath == "same-size.txt" }
        expectEqual(changed?.kind, .differs, "checksum detects same-size changes")
    }
}
