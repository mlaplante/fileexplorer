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
    @ObservationIgnored private let sleeper: @MainActor (Duration) async -> Void
    @ObservationIgnored private var pending: Task<Void, Never>?
    @ObservationIgnored private var generation = 0

    /// `sleeper` exists so tests can control the debounce timer
    /// deterministically instead of racing the wall clock.
    public init(runner: @escaping Runner = GitStatusModel.defaultRunner,
                sleeper: @escaping @MainActor (Duration) async -> Void
                    = { try? await Task.sleep(for: $0) }) {
        self.runner = runner
        self.sleeper = sleeper
    }

    public func refresh(for folder: URL, debounce: Duration = .milliseconds(250)) {
        generation += 1
        let myGeneration = generation
        let standardized = folder.standardizedFileURL
        pending?.cancel()
        pending = Task { [debounce, standardized] in
            await sleeper(debounce)
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
        GitRepoLocator.repoRoot(containing: folder)
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
            process.standardError = FileHandle.nullDevice

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
