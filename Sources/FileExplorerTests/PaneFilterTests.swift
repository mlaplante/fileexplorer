import Foundation
import FileExplorerCore

private func runPaneFilterGit(_ arguments: [String], in directory: URL) throws {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
    process.arguments = [
        "-c", "user.name=t",
        "-c", "user.email=t@t",
        "-c", "commit.gpgsign=false",
    ] + arguments
    process.currentDirectoryURL = directory
    process.environment = [
        "GIT_CONFIG_GLOBAL": "/dev/null",
        "GIT_CONFIG_SYSTEM": "/dev/null",
        "HOME": directory.path,
    ]
    try process.run()
    process.waitUntilExit()
    if process.terminationStatus != 0 {
        throw NSError(domain: "PaneFilterGit", code: Int(process.terminationStatus))
    }
}

@MainActor
func paneFilterTests() async {
    await test("PaneState filter narrows visibleEntries live") {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        try Data("img".utf8).write(to: dir.appendingPathComponent("a.png"))
        try Data("doc".utf8).write(to: dir.appendingPathComponent("b.txt"))
        try FileManager.default.createDirectory(
            at: dir.appendingPathComponent("sub"), withIntermediateDirectories: false)

        let pane = PaneState(url: dir)
        await pane.reload()
        expectEqual(pane.visibleEntries.count, 3, "unfiltered shows all")
        expectEqual(pane.totalCount, 3, "totalCount matches entries")

        pane.filter.preset = .images
        expectEqual(pane.visibleEntries.map(\.name), ["sub", "a.png"],
                    "images filter keeps folder + png, folders first")
        expectEqual(pane.totalCount, 3, "totalCount unaffected by filter")

        pane.filter = FilterState()
        expectEqual(pane.visibleEntries.count, 3, "clearing filter restores all")
    }

    await test("PaneState parses extension text into the filter") {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        try Data().write(to: dir.appendingPathComponent("a.png"))
        try Data().write(to: dir.appendingPathComponent("b.txt"))

        let pane = PaneState(url: dir)
        await pane.reload()

        pane.filterExtensionsText = " .PNG, jpg ,"
        expectEqual(pane.filter.extensions, ["png", "jpg"],
                    "text parsed: trimmed, lowercased, dots stripped, empties dropped")
        expectEqual(pane.visibleEntries.map(\.name), ["a.png"], "filter applied live")

        pane.clearFilters()
        expect(!pane.filter.isActive, "clearFilters deactivates")
        expectEqual(pane.filterExtensionsText, "", "clearFilters empties the draft text")
        expectEqual(pane.visibleEntries.count, 2, "all entries back")
    }

    await test("filter persists across reloads and navigation") {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        try Data().write(to: dir.appendingPathComponent("a.png"))
        try Data().write(to: dir.appendingPathComponent("b.txt"))

        let pane = PaneState(url: dir)
        await pane.reload()
        pane.filter.preset = .images
        await pane.reload()
        expectEqual(pane.visibleEntries.map(\.name), ["a.png"],
                    "filter still applied after reload")
    }

    await test("PaneState hideGitIgnored removes ignored entries only in repos") {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        try runPaneFilterGit(["init", "-q", "-b", "main"], in: dir)
        try Data("ignored.txt\n".utf8).write(to: dir.appendingPathComponent(".gitignore"))
        try Data("clean".utf8).write(to: dir.appendingPathComponent("clean.txt"))
        try Data("ignored".utf8).write(to: dir.appendingPathComponent("ignored.txt"))

        let pane = PaneState(url: dir)
        await pane.reload()
        await pane.gitStatus.refreshNow(for: dir)

        expectEqual(pane.visibleEntries.map(\.name).contains("ignored.txt"), true,
                    "ignored file is visible before toggle")
        pane.filter.hideGitIgnored = true
        expectEqual(pane.visibleEntries.map(\.name).contains("ignored.txt"), false,
                    "ignored file is hidden by toggle")
        expectEqual(pane.visibleEntries.map(\.name).contains("clean.txt"), true,
                    "non-ignored file remains visible")

        pane.filter.hideGitIgnored = nil
        expectEqual(pane.visibleEntries.map(\.name).contains("ignored.txt"), true,
                    "clearing toggle restores ignored file")
    }

    await test("PaneState hideGitIgnored is a no-op outside repos") {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        try Data("file".utf8).write(to: dir.appendingPathComponent("ignored.txt"))

        let pane = PaneState(url: dir)
        await pane.reload()
        pane.filter.hideGitIgnored = true

        expectEqual(pane.visibleEntries.map(\.name), ["ignored.txt"],
                    "non-repo panes do not hide entries")
    }
}
