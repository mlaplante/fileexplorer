import Foundation
import FileExplorerCore

private func makeTempDirectory(prefix: String) throws -> URL {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent(prefix + "-" + UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

private func runGit(_ arguments: [String], in directory: URL) throws {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
    process.arguments = arguments
    process.currentDirectoryURL = directory
    process.environment = [
        "GIT_CONFIG_GLOBAL": "/dev/null",
        "GIT_CONFIG_SYSTEM": "/dev/null",
        "HOME": directory.path,
    ]
    try process.run()
    process.waitUntilExit()
    if process.terminationStatus != 0 {
        throw NSError(domain: "GitRepoLocatorTests", code: Int(process.terminationStatus))
    }
}

@MainActor
func gitRepoLocatorTests() async {
    await test("GitRepoLocator finds injected .git directory at folder") {
        let root = URL(fileURLWithPath: "/tmp/repo", isDirectory: true)
        let result = GitRepoLocator.repoRoot(containing: root) { path in
            path == "/tmp/repo/.git"
        }

        expectEqual(result, root.standardizedFileURL, "folder with .git is repo root")
    }

    await test("GitRepoLocator walks up from deep descendants") {
        let deep = URL(fileURLWithPath: "/tmp/repo/Sources/Nested", isDirectory: true)
        let result = GitRepoLocator.repoRoot(containing: deep) { path in
            path == "/tmp/repo/.git"
        }

        expectEqual(result?.path, "/tmp/repo", "ancestor with .git is returned")
    }

    await test("GitRepoLocator accepts worktree .git files") {
        let child = URL(fileURLWithPath: "/tmp/worktree/sub", isDirectory: true)
        let result = GitRepoLocator.repoRoot(containing: child) { path in
            path == "/tmp/worktree/.git"
        }

        expectEqual(result?.path, "/tmp/worktree", ".git file presence is enough")
    }

    await test("GitRepoLocator returns nil outside repos and terminates at root") {
        var checks = 0
        let result = GitRepoLocator.repoRoot(containing: URL(fileURLWithPath: "/tmp/a/b/c")) { _ in
            checks += 1
            return false
        }

        expectEqual(result, nil, "no repo returns nil")
        expect(checks < 16, "ancestor walk terminates [checks: \(checks)]")
    }

    await test("GitRepoLocator finds a real git init repo") {
        let root = try makeTempDirectory(prefix: "fx-locator")
        defer { try? FileManager.default.removeItem(at: root) }
        try runGit(["init", "-q", "-b", "main"], in: root)

        let nested = root.appendingPathComponent("a/b", isDirectory: true)
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        let result = GitRepoLocator.repoRoot(containing: nested)

        expectEqual(result, root.standardizedFileURL, "real git repo is discovered")
    }

    await test("GitRepoLocator standardizes result URLs") {
        let odd = URL(fileURLWithPath: "/tmp/repo/./child/..", isDirectory: true)
        let result = GitRepoLocator.repoRoot(containing: odd) { path in
            path == "/tmp/repo/.git"
        }

        expectEqual(result?.path, "/tmp/repo", "result path is standardized")
    }
}
