import Foundation
import Observation

@MainActor
@Observable
public final class GitStatusModel {
    public typealias Runner = @Sendable (URL) async -> Data?

    public private(set) var index: GitStatusIndex?
    public var isInRepo: Bool { index != nil }
    public var onChange: (@MainActor () -> Void)?

    @ObservationIgnored private let runner: Runner
    @ObservationIgnored private var pending: Task<Void, Never>?
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var repoRootCache: [String: URL] = [:]
    @ObservationIgnored private var nonRepoFolders = Set<String>()

    public init(runner: @escaping Runner = GitStatusModel.defaultRunner) {
        self.runner = runner
    }

    public func refresh(for folder: URL, debounce: Duration = .milliseconds(250)) {
        generation += 1
        let myGeneration = generation
        let standardized = folder.standardizedFileURL
        pending?.cancel()
        pending = Task { [debounce, standardized] in
            try? await Task.sleep(for: debounce)
            guard !Task.isCancelled else { return }
            await self.runRefresh(for: standardized, generation: myGeneration)
        }
    }

    public func refreshNow(for folder: URL) async {
        generation += 1
        let myGeneration = generation
        pending?.cancel()
        pending = nil
        await runRefresh(for: folder.standardizedFileURL, generation: myGeneration)
    }

    private func runRefresh(for folder: URL, generation myGeneration: Int) async {
        guard let repoRoot = repoRoot(containing: folder) else {
            guard myGeneration == generation else { return }
            index = nil
            onChange?()
            return
        }

        guard let data = await runner(repoRoot) else {
            guard myGeneration == generation else { return }
            index = nil
            onChange?()
            return
        }

        let status = GitStatusParser.parse(data)
        guard myGeneration == generation, !Task.isCancelled else { return }
        index = GitStatusIndex(status: status, repoRoot: repoRoot)
        onChange?()
    }

    private func repoRoot(containing folder: URL) -> URL? {
        let key = folder.standardizedFileURL.path
        if let cached = repoRootCache[key] {
            return cached
        }
        if nonRepoFolders.contains(key) {
            return nil
        }
        if let located = GitRepoLocator.repoRoot(containing: folder) {
            repoRootCache[key] = located
            return located
        }
        nonRepoFolders.insert(key)
        return nil
    }

    public static let defaultRunner: Runner = { repoRoot in
        await Task.detached(priority: .utility) {
            guard FileManager.default.fileExists(atPath: "/usr/bin/git") else {
                return nil
            }

            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
            process.arguments = [
                "-C", repoRoot.path,
                "status",
                "--porcelain=v2",
                "--branch",
                "--ignored=matching",
                "-z",
            ]
            let stdout = Pipe()
            process.standardOutput = stdout
            process.standardError = Pipe()

            do {
                try process.run()
                let data = stdout.fileHandleForReading.readDataToEndOfFile()
                process.waitUntilExit()
                guard process.terminationStatus == 0 else { return nil }
                if data.count <= GitStatusParser.outputCap {
                    return data
                }
                return Data(data.prefix(GitStatusParser.outputCap))
            } catch {
                return nil
            }
        }.value
    }
}
