import Foundation
import Observation

@MainActor
@Observable
public final class DuplicateFinder {
    public private(set) var groups: [DuplicateGroup] = []
    public private(set) var isScanning = false
    public private(set) var isPartial = false
    public private(set) var scannedFileCount = 0

    public static let fileCap = 100_000

    @ObservationIgnored private var scanTask: Task<Void, Never>?
    @ObservationIgnored private var generation = 0

    public init() {}

    public func scan(root: URL) {
        scan(root: root, cap: Self.fileCap)
    }

    public func scan(root: URL, cap: Int) {
        cancel()
        generation += 1
        let currentGeneration = generation
        groups = []
        isPartial = false
        scannedFileCount = 0
        isScanning = true

        let stream = DuplicateScanRunner.stream(root: root.standardizedFileURL, cap: cap)
        scanTask = Task { [weak self] in
            for await snapshot in stream {
                guard !Task.isCancelled else { break }
                guard let self, self.generation == currentGeneration else { continue }
                self.groups = snapshot.groups
                self.isPartial = snapshot.isPartial
                self.scannedFileCount = snapshot.scannedFileCount
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
}

private struct DuplicateScanSnapshot: Sendable {
    let groups: [DuplicateGroup]
    let isPartial: Bool
    let scannedFileCount: Int
    let isFinished: Bool
}

private enum DuplicateScanRunner {
    static func stream(root: URL, cap: Int) -> AsyncStream<DuplicateScanSnapshot> {
        AsyncStream { continuation in
            let task = Task.detached(priority: .userInitiated) {
                await scan(root: root, cap: cap, continuation: continuation)
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private static func scan(
        root: URL,
        cap: Int,
        continuation: AsyncStream<DuplicateScanSnapshot>.Continuation
    ) async {
        defer { continuation.finish() }
        var bySize: [Int64: [URL]] = [:]
        var scannedFileCount = 0
        var isPartial = false
        let keys: [URLResourceKey] = [
            .isDirectoryKey,
            .isRegularFileKey,
            .isSymbolicLinkKey,
            .fileSizeKey,
            .contentModificationDateKey,
        ]

        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: keys,
            options: [],
            errorHandler: { _, _ in true }
        ) else {
            continuation.yield(snapshot(groups: [], isPartial: false,
                                        scannedFileCount: 0, isFinished: true))
            return
        }

        // `scan` is now async (Task 7 parallel hashing); FileManager's
        // NSEnumerator-based directory enumerator can't be driven by a
        // `for-in` loop from an async context on the macOS 27 SDK
        // (`NSEnumerator.makeIterator()` is `@available(*, noasync)`), so
        // step it manually via `nextObject()` instead.
        while let next = enumerator.nextObject() {
            guard let url = next as? URL else { continue }
            if Task.isCancelled { break }
            guard let values = try? url.resourceValues(forKeys: Set(keys)) else {
                continue
            }
            if values.isSymbolicLink == true {
                if values.isDirectory == true { enumerator.skipDescendants() }
                continue
            }
            if values.isDirectory == true {
                if isUnreadableDirectory(url) { enumerator.skipDescendants() }
                continue
            }
            guard values.isRegularFile == true else { continue }
            if scannedFileCount >= cap {
                isPartial = true
                break
            }
            scannedFileCount += 1
            let size = Int64(values.fileSize ?? 0)
            guard size > 0 else { continue }
            bySize[size, default: []].append(url.standardizedFileURL)
            if scannedFileCount.isMultiple(of: 200) {
                continuation.yield(snapshot(groups: [], isPartial: false,
                                            scannedFileCount: scannedFileCount,
                                            isFinished: false))
            }
        }

        let prefilterThreshold: Int64 = 128 * 1024
        let prefixBytes = 65_536
        var groups: [DuplicateGroup] = []
        for size in bySize.keys.sorted() {
            if Task.isCancelled { break }
            guard let urls = bySize[size], urls.count >= 2 else { continue }

            // Cheap prefilter for large files: same-size-but-different files
            // usually diverge in the first 64 KB, so a prefix hash eliminates
            // them without reading whole files.
            var candidateBuckets: [[URL]]
            if size > prefilterThreshold {
                var byPrefix: [String: [URL]] = [:]
                for url in urls {
                    if Task.isCancelled { break }
                    guard case .success(let prefix) = FileHasher.sha256(
                        of: url, firstBytes: prefixBytes) else { continue }
                    byPrefix[prefix, default: []].append(url)
                }
                candidateBuckets = byPrefix.values.filter { $0.count >= 2 }
            } else {
                candidateBuckets = [urls]
            }

            var byHash: [String: [DuplicateMember]] = [:]
            for bucket in candidateBuckets {
                if Task.isCancelled { break }
                for (url, hash) in await parallelFullHashes(
                    of: bucket.sorted(by: { $0.path < $1.path })) {
                    let modified = (try? url.resourceValues(
                        forKeys: [.contentModificationDateKey]
                    ).contentModificationDate) ?? .distantPast
                    byHash[hash, default: []].append(
                        DuplicateMember(url: url, modified: modified))
                }
            }
            let bucketGroups = byHash.compactMap { hash, members -> DuplicateGroup? in
                guard members.count >= 2 else { return nil }
                return DuplicateGroup(hash: hash, size: size,
                                      members: sortedMembers(members))
            }
            if !bucketGroups.isEmpty {
                groups.append(contentsOf: bucketGroups)
                continuation.yield(snapshot(groups: sortedGroups(groups),
                                            isPartial: isPartial,
                                            scannedFileCount: scannedFileCount,
                                            isFinished: false))
            }
        }

        continuation.yield(snapshot(groups: sortedGroups(groups),
                                    isPartial: isPartial,
                                    scannedFileCount: scannedFileCount,
                                    isFinished: true))
    }

    /// Full hashes of `urls`, bounded to the core count so a duplicate scan
    /// can't starve the machine. Results keep no particular order; callers
    /// sort members before building groups.
    private static func parallelFullHashes(of urls: [URL]) async -> [(URL, String)] {
        let width = min(ProcessInfo.processInfo.activeProcessorCount, 8)
        var results: [(URL, String)] = []
        var iterator = urls.makeIterator()
        await withTaskGroup(of: (URL, String)?.self) { group in
            for _ in 0..<width {
                guard let url = iterator.next() else { break }
                group.addTask {
                    guard !Task.isCancelled,
                          case .success(let hash) = FileHasher.sha256(of: url)
                    else { return nil }
                    return (url, hash)
                }
            }
            while let finished = await group.next() {
                if let finished { results.append(finished) }
                if let url = iterator.next() {
                    group.addTask {
                        guard !Task.isCancelled,
                              case .success(let hash) = FileHasher.sha256(of: url)
                        else { return nil }
                        return (url, hash)
                    }
                }
            }
        }
        return results
    }

    private static func snapshot(groups: [DuplicateGroup], isPartial: Bool,
                                 scannedFileCount: Int, isFinished: Bool)
        -> DuplicateScanSnapshot {
        DuplicateScanSnapshot(groups: groups, isPartial: isPartial,
                              scannedFileCount: scannedFileCount,
                              isFinished: isFinished)
    }

    private static func sortedGroups(_ groups: [DuplicateGroup]) -> [DuplicateGroup] {
        groups.sorted { lhs, rhs in
            if lhs.wastedBytes != rhs.wastedBytes {
                return lhs.wastedBytes > rhs.wastedBytes
            }
            if lhs.size != rhs.size { return lhs.size > rhs.size }
            return lhs.hash < rhs.hash
        }
    }

    private static func sortedMembers(_ members: [DuplicateMember]) -> [DuplicateMember] {
        members.sorted { lhs, rhs in
            if lhs.modified != rhs.modified { return lhs.modified > rhs.modified }
            return lhs.url.path < rhs.url.path
        }
    }

    private static func isUnreadableDirectory(_ url: URL) -> Bool {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              let permissions = attributes[.posixPermissions] as? NSNumber
        else { return false }
        return permissions.intValue & 0o444 == 0
    }
}
