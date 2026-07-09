import Foundation
import Observation

public struct UsageRemovalToken: Sendable {
    fileprivate let generation: Int
    fileprivate let root: URL
}

@MainActor
@Observable
public final class UsageScanner {
    public private(set) var rows: [UsageRow] = []
    public private(set) var totalBytes: Int64 = 0
    public private(set) var isScanning = false
    public private(set) var isPartial = false
    public private(set) var visitedEntryCount = 0

    public static let entryCap = 250_000

    @ObservationIgnored private var scanTask: Task<Void, Never>?
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var root: URL?
    @ObservationIgnored private var removals: [URL: Int64] = [:]

    public init() {}

    public func scan(root: URL) {
        scan(root: root, cap: Self.entryCap)
    }

    public func scan(root: URL, cap: Int) {
        cancel()
        generation += 1
        let currentGeneration = generation
        rows = []
        totalBytes = 0
        visitedEntryCount = 0
        isPartial = false
        isScanning = true
        self.root = root.standardizedFileURL
        removals = [:]

        let stream = UsageScanRunner.stream(root: root.standardizedFileURL, cap: cap)
        scanTask = Task { [weak self] in
            for await snapshot in stream {
                guard !Task.isCancelled else { break }
                guard let self, self.generation == currentGeneration else { continue }
                self.apply(snapshot)
                self.isPartial = snapshot.isPartial
                self.visitedEntryCount = snapshot.visitedEntryCount
                if snapshot.isFinished {
                    self.isScanning = false
                }
            }
            guard let self, self.generation == currentGeneration else { return }
            self.isScanning = false
        }
    }

    public func cancel() {
        generation += 1
        scanTask?.cancel()
        scanTask = nil
        isScanning = false
    }

    public func removalToken() -> UsageRemovalToken? {
        guard let root else { return nil }
        return UsageRemovalToken(generation: generation, root: root)
    }

    public func remove(url: URL, bytes: Int64) {
        guard let token = removalToken() else { return }
        remove(url: url, bytes: bytes, token: token)
    }

    public func remove(url: URL, bytes: Int64, token: UsageRemovalToken) {
        guard token.generation == generation,
              let root,
              token.root.standardizedFileURL == root.standardizedFileURL,
              isUnderRoot(url: url, root: root)
        else { return }
        let standardized = url.standardizedFileURL
        removals[standardized, default: 0] += bytes
        rows = UsageRanking.subtracting(standardized, bytes: bytes, from: rows)
        totalBytes = max(0, totalBytes - bytes)
    }

    private func apply(_ snapshot: UsageScanSnapshot) {
        var nextRows = snapshot.rows
        var nextTotal = snapshot.totalBytes
        for (url, bytes) in removals {
            nextRows = UsageRanking.subtracting(url, bytes: bytes, from: nextRows)
            nextTotal = max(0, nextTotal - bytes)
        }
        rows = nextRows
        totalBytes = nextTotal
    }

    private func isUnderRoot(url: URL, root: URL) -> Bool {
        let rootPath = root.standardizedFileURL.path
        let path = url.standardizedFileURL.path
        return path == rootPath || path.hasPrefix(rootPath == "/" ? "/" : rootPath + "/")
    }
}

private struct UsageScanSnapshot: Sendable {
    let rows: [UsageRow]
    let totalBytes: Int64
    let isPartial: Bool
    let isFinished: Bool
    let visitedEntryCount: Int
}

private enum UsageScanRunner {
    private struct ChildTotal: Sendable {
        var bytes: Int64
        var items: Int
        var isDirectory: Bool
    }

    static func stream(root: URL, cap: Int) -> AsyncStream<UsageScanSnapshot> {
        AsyncStream { continuation in
            let task = Task.detached(priority: .userInitiated) {
                scan(root: root, cap: cap, continuation: continuation)
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private static func scan(root: URL, cap: Int,
                             continuation: AsyncStream<UsageScanSnapshot>.Continuation) {
        defer { continuation.finish() }
        var totals: [URL: ChildTotal] = [:]
        var totalBytes: Int64 = 0
        var visited = 0
        var isPartial = false
        let rootPath = root.standardizedFileURL.path
        let rootPrefix = rootPath == "/" ? "/" : rootPath + "/"
        // Reused across every entry: constructing this from `rootPrefix` per
        // entry (250k+ times on a full scan) dominated the hot path.
        let childBaseURL = URL(fileURLWithPath: rootPrefix)
        // Real trees have orders of magnitude more descendants than
        // top-level children, so ancestor URLs repeat constantly; cache
        // them by name.
        var childURLCache: [String: URL] = [:]
        let keys: [URLResourceKey] = [
            .isDirectoryKey,
            .isRegularFileKey,
            .isSymbolicLinkKey,
            .fileSizeKey,
        ]
        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: keys,
            options: [],
            errorHandler: { _, _ in true }
        ) else {
            continuation.yield(snapshot(totals: totals, totalBytes: totalBytes,
                                        isPartial: false, isFinished: true))
            return
        }

        for case let url as URL in enumerator {
            if Task.isCancelled { break }
            if visited >= cap {
                isPartial = true
                break
            }
            visited += 1

            guard let values = try? url.resourceValues(forKeys: Set(keys)) else {
                continue
            }
            if values.isSymbolicLink == true {
                if values.isDirectory == true { enumerator.skipDescendants() }
                continue
            }
            if values.isDirectory == true {
                if isUnreadableDirectory(url) {
                    enumerator.skipDescendants()
                    continue
                }
                if let (child, _) = immediateChild(for: url, rootPrefix: rootPrefix,
                                                    childBaseURL: childBaseURL,
                                                    cache: &childURLCache) {
                    totals[child, default: ChildTotal(bytes: 0, items: 0,
                                                      isDirectory: true)].isDirectory = true
                }
                continue
            }
            guard values.isRegularFile == true,
                  let (child, isDirectChild) = immediateChild(for: url, rootPrefix: rootPrefix,
                                                               childBaseURL: childBaseURL,
                                                               cache: &childURLCache)
            else { continue }

            let bytes = Int64(values.fileSize ?? 0)
            var total = totals[child] ?? ChildTotal(bytes: 0, items: 0,
                                                    isDirectory: !isDirectChild)
            total.bytes += bytes
            total.items += 1
            totals[child] = total
            totalBytes += bytes

            if visited.isMultiple(of: 200) {
                continuation.yield(snapshot(totals: totals, totalBytes: totalBytes,
                                            isPartial: false, isFinished: false,
                                            visited: visited))
            }
        }

        continuation.yield(snapshot(totals: totals, totalBytes: totalBytes,
                                    isPartial: isPartial, isFinished: true,
                                    visited: visited))
    }

    /// Resolves `url`'s ancestor directly under `root` and whether `url` *is*
    /// that ancestor. `standardizedFileURL` is computed once here (the
    /// caller must not recompute it), and ancestor URLs are cached by name
    /// since a scan revisits the same handful of top-level children for
    /// every descendant entry.
    /// Callers must supply a cache scoped to a single rootPrefix — entries
    /// are keyed by name only.
    private static func immediateChild(
        for url: URL, rootPrefix: String, childBaseURL: URL,
        cache: inout [String: URL]
    ) -> (child: URL, isDirectChild: Bool)? {
        let standardized = url.standardizedFileURL
        let path = standardized.path
        guard path.hasPrefix(rootPrefix) else { return nil }
        let relative = path.dropFirst(rootPrefix.count)
        guard let slash = relative.firstIndex(of: "/") else {
            return relative.isEmpty ? nil : (standardized, true)
        }
        let name = String(relative[..<slash])
        if let cached = cache[name] { return (cached, false) }
        let child = childBaseURL.appendingPathComponent(name).standardizedFileURL
        cache[name] = child
        return (child, false)
    }

    private static func isUnreadableDirectory(_ url: URL) -> Bool {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              let permissions = attributes[.posixPermissions] as? NSNumber
        else { return false }
        return permissions.intValue & 0o444 == 0
    }

    private static func snapshot(totals: [URL: ChildTotal], totalBytes: Int64,
                                 isPartial: Bool, isFinished: Bool,
                                 visited: Int = 0)
        -> UsageScanSnapshot {
        let rankingInput = Dictionary(uniqueKeysWithValues: totals.map { url, total in
            (url, (bytes: total.bytes, items: total.items,
                   isDirectory: total.isDirectory))
        })
        return UsageScanSnapshot(
            rows: UsageRanking.rows(childTotals: rankingInput),
            totalBytes: totalBytes,
            isPartial: isPartial,
            isFinished: isFinished,
            visitedEntryCount: visited)
    }
}
