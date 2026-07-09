import Foundation
import Observation

@MainActor
@Observable
public final class UsageScanner {
    public private(set) var rows: [UsageRow] = []
    public private(set) var totalBytes: Int64 = 0
    public private(set) var isScanning = false
    public private(set) var isPartial = false

    public static let entryCap = 250_000

    @ObservationIgnored private var scanTask: Task<Void, Never>?
    @ObservationIgnored private var generation = 0

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
        isPartial = false
        isScanning = true

        let stream = UsageScanRunner.stream(root: root.standardizedFileURL, cap: cap)
        scanTask = Task { [weak self] in
            for await snapshot in stream {
                guard !Task.isCancelled else { break }
                guard let self, self.generation == currentGeneration else { continue }
                self.rows = snapshot.rows
                self.totalBytes = snapshot.totalBytes
                self.isPartial = snapshot.isPartial
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

    public func remove(url: URL, bytes: Int64) {
        rows = UsageRanking.subtracting(url, bytes: bytes, from: rows)
        totalBytes = max(0, totalBytes - bytes)
    }
}

private struct UsageScanSnapshot: Sendable {
    let rows: [UsageRow]
    let totalBytes: Int64
    let isPartial: Bool
    let isFinished: Bool
}

private enum UsageScanRunner {
    private struct ChildTotal: Sendable {
        var bytes: Int64
        var items: Int
        var isDirectory: Bool
    }

    static func stream(root: URL, cap: Int) -> AsyncStream<UsageScanSnapshot> {
        AsyncStream { continuation in
            Task.detached(priority: .userInitiated) {
                scan(root: root, cap: cap, continuation: continuation)
            }
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
                if let child = immediateChild(for: url, rootPrefix: rootPrefix) {
                    totals[child, default: ChildTotal(bytes: 0, items: 0,
                                                      isDirectory: true)].isDirectory = true
                }
                continue
            }
            guard values.isRegularFile == true,
                  let child = immediateChild(for: url, rootPrefix: rootPrefix)
            else { continue }

            let bytes = Int64(values.fileSize ?? 0)
            let isDirectChild = child.standardizedFileURL.path == url.standardizedFileURL.path
            var total = totals[child] ?? ChildTotal(bytes: 0, items: 0,
                                                    isDirectory: !isDirectChild)
            total.bytes += bytes
            total.items += 1
            totals[child] = total
            totalBytes += bytes

            if visited.isMultiple(of: 200) {
                continuation.yield(snapshot(totals: totals, totalBytes: totalBytes,
                                            isPartial: false, isFinished: false))
            }
        }

        continuation.yield(snapshot(totals: totals, totalBytes: totalBytes,
                                    isPartial: isPartial, isFinished: true))
    }

    private static func immediateChild(for url: URL, rootPrefix: String) -> URL? {
        let path = url.standardizedFileURL.path
        guard path.hasPrefix(rootPrefix) else { return nil }
        let relative = String(path.dropFirst(rootPrefix.count))
        guard let first = relative.split(separator: "/", maxSplits: 1).first else {
            return nil
        }
        return URL(fileURLWithPath: rootPrefix).appendingPathComponent(String(first))
            .standardizedFileURL
    }

    private static func isUnreadableDirectory(_ url: URL) -> Bool {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              let permissions = attributes[.posixPermissions] as? NSNumber
        else { return false }
        return permissions.intValue & 0o444 == 0
    }

    private static func snapshot(totals: [URL: ChildTotal], totalBytes: Int64,
                                 isPartial: Bool, isFinished: Bool)
        -> UsageScanSnapshot {
        let rankingInput = Dictionary(uniqueKeysWithValues: totals.map { url, total in
            (url, (bytes: total.bytes, items: total.items,
                   isDirectory: total.isDirectory))
        })
        return UsageScanSnapshot(
            rows: UsageRanking.rows(childTotals: rankingInput),
            totalBytes: totalBytes,
            isPartial: isPartial,
            isFinished: isFinished)
    }
}
