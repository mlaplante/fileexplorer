import Foundation
import FileExplorerCore

private func porcelainData(_ records: [String]) -> Data {
    records.joined(separator: "\0").appending("\0").data(using: .utf8)!
}

@MainActor
func gitStatusParserTests() async {
    await test("GitStatusParser parses branch headers and porcelain states") {
        let data = porcelainData([
            "# branch.oid 1234567890abcdef",
            "# branch.head main",
            "1 .M N... 100644 100644 100644 aaa bbb modified.txt",
            "1 M. N... 100644 100644 100644 aaa bbb staged.txt",
            "1 MM N... 100644 100644 100644 aaa bbb both.txt",
            "1 .M S.MU 160000 160000 160000 aaa bbb submodule",
            "u UU N... 100644 100644 100644 100644 aaa bbb ccc conflict.txt",
            "? untracked file.txt",
            "! build/",
            "2 R. N... 100644 100644 100644 aaa bbb R100 renamed new.txt",
            "renamed old.txt",
        ])

        let status = GitStatusParser.parse(data)

        expectEqual(status.branch, "main", "branch.head becomes branch")
        expectEqual(status.detachedOID, nil, "attached branch has no detached OID")
        expectEqual(status.states["modified.txt"], .modified, "worktree change is modified")
        expectEqual(status.states["staged.txt"], .staged, "index change is staged")
        expectEqual(status.states["both.txt"], .staged, "index change wins over worktree change")
        expectEqual(status.states["submodule"], .modified, "dirty submodule is modified")
        expectEqual(status.states["conflict.txt"], .conflicted, "unmerged record is conflicted")
        expectEqual(status.states["untracked file.txt"], .untracked, "question record is untracked")
        expectEqual(status.ignored, ["build/"], "ignored records populate ignored set")
        expectEqual(status.states["renamed new.txt"], .staged, "rename new path is staged")
        expectEqual(status.states["renamed old.txt"], nil, "rename old path is ignored")
        expectEqual(status.changedCount, 7, "changedCount counts non-ignored states")
    }

    await test("GitStatusParser parses detached head short OID") {
        let data = porcelainData([
            "# branch.oid abc1234567890",
            "# branch.head (detached)",
        ])

        let status = GitStatusParser.parse(data)

        expectEqual(status.branch, nil, "detached head has nil branch")
        expectEqual(status.detachedOID, "abc1234", "detached OID is shortened")
    }

    await test("GitStatusParser handles empty input") {
        let status = GitStatusParser.parse(Data())

        expectEqual(status.branch, nil, "empty status has no branch")
        expectEqual(status.states, [:], "empty status has no changed states")
        expectEqual(status.ignored, [], "empty status has no ignored paths")
        expectEqual(status.changedCount, 0, "empty status has zero changed count")
    }

    await test("GitStatusParser truncates oversized input at last complete record") {
        let branch = "# branch.head main\0"
        let fillerPath = String(repeating: "x", count: GitStatusParser.outputCap + 128)
        let oversized = branch + "1 .M N... 100644 100644 100644 aaa bbb \(fillerPath)"
        let status = GitStatusParser.parse(oversized.data(using: .utf8)!)

        expectEqual(status.branch, "main", "branch before cap survives")
        expectEqual(status.states, [:], "incomplete oversized record is ignored")
        expectEqual(status.changedCount, 0, "truncated incomplete record is not counted")
    }

    await test("GitStatusParser trims exactly capped input at last complete record") {
        let branch = "# branch.head main\0"
        let partial = "1 .M N... 100644 100644 100644 aaa bbb garbled"
        let paddingCount = GitStatusParser.outputCap - branch.utf8.count - partial.utf8.count
        let capped = branch + partial + String(repeating: "x", count: paddingCount)
        let status = GitStatusParser.parse(capped.data(using: .utf8)!)

        expectEqual(capped.utf8.count, GitStatusParser.outputCap, "fixture is exactly capped")
        expectEqual(status.branch, "main", "branch before exact cap survives")
        expectEqual(status.states, [:], "partial exact-cap record is ignored")
        expectEqual(status.changedCount, 0, "partial exact-cap record is not counted")
    }

    await test("GitStatusParser preserves spaces and UTF-8 paths") {
        let data = porcelainData([
            "1 .M N... 100644 100644 100644 aaa bbb Café Notes.md",
            "? nested/space path/文件.txt",
        ])

        let status = GitStatusParser.parse(data)

        expectEqual(status.states["Café Notes.md"], .modified, "UTF-8 ordinary path survives")
        expectEqual(status.states["nested/space path/文件.txt"], .untracked, "UTF-8 untracked path survives")
    }
}
