import Foundation
import FileExplorerCore

private func makeGitModelTempDirectory(prefix: String) throws -> URL {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent(prefix + "-" + UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

private func runIsolatedGit(_ arguments: [String], in directory: URL) throws {
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
        throw NSError(domain: "GitStatusModelTests", code: Int(process.terminationStatus))
    }
}

private func writeFile(_ url: URL, _ text: String) throws {
    try FileManager.default.createDirectory(
        at: url.deletingLastPathComponent(),
        withIntermediateDirectories: true)
    try text.data(using: .utf8)!.write(to: url)
}

private func porcelainStatus(_ records: [String]) -> Data {
    records.joined(separator: "\0").appending("\0").data(using: .utf8)!
}

private actor RunCounter {
    private(set) var count = 0
    func increment() { count += 1 }
}

@MainActor
func gitStatusModelTests() async {
    await test("GitStatusModel leaves non-repo folders unloaded") {
        let folder = try makeGitModelTempDirectory(prefix: "fx-model-nonrepo")
        defer { try? FileManager.default.removeItem(at: folder) }

        let model = GitStatusModel()
        await model.refreshNow(for: folder)

        expectEqual(model.index == nil, true, "non-repo has nil index")
        expectEqual(model.isInRepo, false, "non-repo is not in repo")
    }

    await test("GitStatusModel loads real repo states") {
        let repo = try makeGitModelTempDirectory(prefix: "fx-model-repo")
        defer { try? FileManager.default.removeItem(at: repo) }
        try runIsolatedGit(["init", "-q", "-b", "main"], in: repo)

        let clean = repo.appendingPathComponent("clean.txt")
        let modified = repo.appendingPathComponent("modified.txt")
        let staged = repo.appendingPathComponent("staged.txt")
        let untracked = repo.appendingPathComponent("untracked.txt")
        let gitignore = repo.appendingPathComponent(".gitignore")
        let ignored = repo.appendingPathComponent("build/x.o")

        try writeFile(clean, "clean\n")
        try writeFile(modified, "before\n")
        try runIsolatedGit(["add", "clean.txt", "modified.txt"], in: repo)
        try runIsolatedGit(["commit", "-q", "-m", "initial"], in: repo)
        try writeFile(modified, "after\n")
        try writeFile(staged, "staged\n")
        try runIsolatedGit(["add", "staged.txt"], in: repo)
        try writeFile(untracked, "new\n")
        try writeFile(gitignore, "build/\n")
        try writeFile(ignored, "object\n")

        let model = GitStatusModel()
        await model.refreshNow(for: repo)

        expectEqual(model.index?.state(for: modified), .modified, "modified file is modified")
        expectEqual(model.index?.state(for: staged), .staged, "added file is staged")
        expectEqual(model.index?.state(for: untracked), .untracked, "new file is untracked")
        expectEqual(model.index?.state(for: clean), .clean, "committed file is clean")
        expectEqual(model.index?.isIgnored(repo.appendingPathComponent("build", isDirectory: true)), true,
                    "ignored directory is marked ignored")
        expectEqual(model.index?.branchLabel, "main", "branch label is main")
        expectEqual(model.index?.changedCount, 4, "changed count includes .gitignore plus three changed files")
    }

    await test("GitStatusModel debounces rapid refresh calls") {
        let repo = try makeGitModelTempDirectory(prefix: "fx-model-debounce")
        defer { try? FileManager.default.removeItem(at: repo) }
        try FileManager.default.createDirectory(at: repo.appendingPathComponent(".git", isDirectory: true),
                                                withIntermediateDirectories: true)
        let counter = RunCounter()
        let model = GitStatusModel { _ in
            await counter.increment()
            return porcelainStatus(["# branch.head main"])
        }

        model.refresh(for: repo, debounce: .milliseconds(50))
        try? await Task.sleep(for: .milliseconds(10))
        model.refresh(for: repo, debounce: .milliseconds(50))
        try? await Task.sleep(for: .milliseconds(150))

        expectEqual(await counter.count, 1, "rapid refreshes coalesce into one runner call")
        expectEqual(model.index?.branchLabel, "main", "debounced refresh publishes status")
    }

    await test("GitStatusModel discards superseded refresh results") {
        let repoA = try makeGitModelTempDirectory(prefix: "fx-model-a")
        let repoB = try makeGitModelTempDirectory(prefix: "fx-model-b")
        defer {
            try? FileManager.default.removeItem(at: repoA)
            try? FileManager.default.removeItem(at: repoB)
        }
        try FileManager.default.createDirectory(at: repoA.appendingPathComponent(".git", isDirectory: true),
                                                withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: repoB.appendingPathComponent(".git", isDirectory: true),
                                                withIntermediateDirectories: true)
        let model = GitStatusModel { root in
            if root.standardizedFileURL.path == repoA.standardizedFileURL.path {
                try? await Task.sleep(for: .milliseconds(150))
                return porcelainStatus(["# branch.head main", "? late-a.txt"])
            }
            return porcelainStatus(["# branch.head main", "? current-b.txt"])
        }

        let first = Task { await model.refreshNow(for: repoA) }
        try? await Task.sleep(for: .milliseconds(20))
        await model.refreshNow(for: repoB)
        await first.value

        expectEqual(model.index?.state(for: repoB.appendingPathComponent("current-b.txt")), .untracked,
                    "newer repo result lands")
        expectEqual(model.index?.state(for: repoA.appendingPathComponent("late-a.txt")), .clean,
                    "late older repo result is discarded")
    }
}
