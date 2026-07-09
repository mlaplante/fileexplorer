import Foundation
import FileExplorerCore

@MainActor
func gitStatusIndexTests() async {
    let repoRoot = URL(fileURLWithPath: "/tmp/repo", isDirectory: true)
    let status = GitRepoStatus(
        branch: "main",
        states: [
            "README.md": .modified,
            "Sources/App.swift": .staged,
            "Sources/Nested/conflict.txt": .conflicted,
            "docs/draft.md": .untracked,
        ],
        ignored: ["build/"]
    )
    let index = GitStatusIndex(status: status, repoRoot: repoRoot)

    await test("GitStatusIndex maps file URLs through repo-relative paths") {
        expectEqual(index.state(for: repoRoot.appendingPathComponent("README.md")), .modified,
                    "root file lookup resolves modified state")
        expectEqual(index.state(for: repoRoot.appendingPathComponent("Sources/App.swift")), .staged,
                    "nested file lookup resolves staged state")
        expectEqual(index.state(for: repoRoot.appendingPathComponent("clean.txt")), .clean,
                    "missing file lookup is clean")
    }

    await test("GitStatusIndex aggregates folder state by priority") {
        expectEqual(index.state(for: repoRoot.appendingPathComponent("Sources", isDirectory: true)), .conflicted,
                    "folder aggregates highest-priority descendant")
        expectEqual(index.state(for: repoRoot.appendingPathComponent("docs", isDirectory: true)), .untracked,
                    "folder aggregates untracked descendants")
        expectEqual(index.state(for: repoRoot.appendingPathComponent("empty", isDirectory: true)), .clean,
                    "folder without changed descendants is clean")
    }

    await test("GitStatusIndex aggregates repo root") {
        expectEqual(index.state(for: repoRoot), .conflicted,
                    "repo root aggregates all changed paths")
    }

    await test("GitStatusIndex treats outside URLs as clean") {
        let outside = URL(fileURLWithPath: "/tmp/repo-other/README.md")
        expectEqual(index.state(for: outside), .clean, "outside path has clean state")
        expectEqual(index.isIgnored(outside), false, "outside path is not ignored")
    }

    await test("GitStatusIndex matches ignored directories and descendants") {
        expectEqual(index.isIgnored(repoRoot.appendingPathComponent("build", isDirectory: true)), true,
                    "ignored directory itself is ignored")
        expectEqual(index.isIgnored(repoRoot.appendingPathComponent("build/obj.o")), true,
                    "descendant of ignored directory is ignored")
        expectEqual(index.isIgnored(repoRoot.appendingPathComponent("build-output/obj.o")), false,
                    "similarly-prefixed path is not ignored")
    }

    await test("GitStatusIndex does not aggregate ignored entries") {
        let ignoredOnly = GitRepoStatus(branch: "main", states: [:], ignored: ["DerivedData/"])
        let ignoredIndex = GitStatusIndex(status: ignoredOnly, repoRoot: repoRoot)

        expectEqual(ignoredIndex.state(for: repoRoot), .clean,
                    "ignored-only repo root is clean")
        expectEqual(ignoredIndex.state(for: repoRoot.appendingPathComponent("DerivedData", isDirectory: true)), .clean,
                    "ignored directory contributes no aggregate state")
    }

    await test("GitStatusIndex resolves collapsed untracked directories and descendants") {
        let status = GitRepoStatus(
            branch: "main",
            states: [
                "sub/": .untracked,
                "outer/nested/": .untracked,
            ]
        )
        let index = GitStatusIndex(status: status, repoRoot: repoRoot)

        expectEqual(index.state(for: repoRoot.appendingPathComponent("sub", isDirectory: true)), .untracked,
                    "collapsed untracked directory row is untracked")
        expectEqual(index.state(for: repoRoot.appendingPathComponent("sub/a.txt")), .untracked,
                    "file inside collapsed untracked directory is untracked")
        expectEqual(index.state(for: repoRoot.appendingPathComponent("outer", isDirectory: true)), .untracked,
                    "ancestor of nested collapsed untracked directory aggregates")
        expectEqual(index.state(for: repoRoot.appendingPathComponent("outer/nested", isDirectory: true)), .untracked,
                    "nested collapsed untracked directory row is untracked")
        expectEqual(index.state(for: repoRoot.appendingPathComponent("outer/nested/a.txt")), .untracked,
                    "descendant of nested collapsed untracked directory is untracked")
    }

    await test("GitStatusIndex formats branch labels and changed count") {
        expectEqual(index.branchLabel, "main", "attached branch label is branch name")
        expectEqual(index.changedCount, 4, "changedCount mirrors status")

        let detached = GitStatusIndex(
            status: GitRepoStatus(detachedOID: "abc1234", states: ["x": .modified]),
            repoRoot: repoRoot
        )
        expectEqual(detached.branchLabel, "detached abc1234", "detached label includes short OID")
    }
}
