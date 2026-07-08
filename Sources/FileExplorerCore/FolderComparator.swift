import Foundation

/// Pure folder-compare engine. `listing` is the only filesystem-touching
/// piece (blocking — call off the main actor); classification, row badging,
/// and sync planning are pure functions over value types.
public enum FolderComparator {
    public struct Entry: Equatable, Sendable {
        public let relativePath: String
        public let size: Int64
        public let modified: Date
        public let isDirectory: Bool

        public init(relativePath: String, size: Int64, modified: Date,
                    isDirectory: Bool) {
            self.relativePath = relativePath
            self.size = size
            self.modified = modified
            self.isDirectory = isDirectory
        }
    }

    public struct Result: Equatable, Sendable {
        public var onlyLeft: [String] = []
        public var onlyRight: [String] = []
        public var differs: [String] = []

        public init() {}

        public var isEmpty: Bool {
            onlyLeft.isEmpty && onlyRight.isEmpty && differs.isEmpty
        }
    }

    public enum Side: Sendable { case left, right }

    public enum Badge: Equatable, Sendable {
        case onlyHere        // exists on this side only
        case differs         // same path, different content
        case containsChanges // directory with affected descendants
    }

    public enum Direction: Sendable { case leftToRight, rightToLeft }

    public enum OperationKind: Equatable, Sendable { case copy, overwrite }

    public struct SyncOperation: Equatable, Sendable {
        public let relativePath: String
        public let kind: OperationKind

        public init(relativePath: String, kind: OperationKind) {
            self.relativePath = relativePath
            self.kind = kind
        }
    }

    /// Recursive walk producing root-relative entries. Hidden files skipped
    /// unless included; package internals always descended (a folder-diff
    /// tool should see inside bundles). Bounded by `entryCap`.
    public static func listing(root: URL, includeHidden: Bool,
                               entryCap: Int = 50_000) -> [Entry] {
        let keys: [URLResourceKey] = [.isDirectoryKey, .fileSizeKey,
                                      .contentModificationDateKey]
        guard let enumerator = FileManager.default.enumerator(
            at: root, includingPropertiesForKeys: keys,
            options: includeHidden ? [] : [.skipsHiddenFiles]) else {
            return []
        }
        let rootPath = root.standardizedFileURL.path
        var entries: [Entry] = []
        for case let url as URL in enumerator {
            if entries.count >= entryCap { break }
            guard let rv = try? url.resourceValues(forKeys: Set(keys)) else { continue }
            let full = url.standardizedFileURL.path
            guard full.hasPrefix(rootPath + "/") else { continue }
            entries.append(Entry(
                relativePath: String(full.dropFirst(rootPath.count + 1)),
                size: Int64(rv.fileSize ?? 0),
                modified: rv.contentModificationDate ?? .distantPast,
                isDirectory: rv.isDirectory ?? false))
        }
        return entries
    }

    /// Files differ on size or mtime (beyond tolerance); directories only
    /// contribute existence. A path that is a file on one side and a
    /// directory on the other counts as differing.
    public static func compare(left: [Entry], right: [Entry],
                               mtimeTolerance: TimeInterval = 2) -> Result {
        let leftMap = Dictionary(uniqueKeysWithValues: left.map { ($0.relativePath, $0) })
        let rightMap = Dictionary(uniqueKeysWithValues: right.map { ($0.relativePath, $0) })
        var result = Result()
        for (path, l) in leftMap {
            guard let r = rightMap[path] else {
                result.onlyLeft.append(path)
                continue
            }
            if l.isDirectory != r.isDirectory {
                result.differs.append(path)
            } else if !l.isDirectory {
                if l.size != r.size
                    || abs(l.modified.timeIntervalSince(r.modified)) > mtimeTolerance {
                    result.differs.append(path)
                }
            }
        }
        for path in rightMap.keys where leftMap[path] == nil {
            result.onlyRight.append(path)
        }
        result.onlyLeft.sort()
        result.onlyRight.sort()
        result.differs.sort()
        return result
    }

    /// Row badge for a visible entry. Directories that are ancestors of any
    /// affected path badge as `containsChanges` so differences deeper in the
    /// tree stay discoverable from the top level.
    public static func badge(for relativePath: String, isDirectory: Bool,
                             side: Side, in result: Result) -> Badge? {
        let own = side == .left ? result.onlyLeft : result.onlyRight
        if own.contains(relativePath) { return .onlyHere }
        if result.differs.contains(relativePath) { return .differs }
        if isDirectory {
            let prefix = relativePath + "/"
            let affected = own + result.differs
                + (side == .left ? result.onlyRight : result.onlyLeft)
            if affected.contains(where: { $0.hasPrefix(prefix) }) {
                return .containsChanges
            }
        }
        return nil
    }

    /// Operations to make the DESTINATION match the source side: copy every
    /// only-source item (top-most only — descendants ride along with the
    /// recursive copy) and overwrite every differing file. Sorted for a
    /// stable preview.
    public static func syncPlan(result: Result, direction: Direction)
        -> [SyncOperation] {
        let onlySource = direction == .leftToRight ? result.onlyLeft : result.onlyRight
        let sourceSet = Set(onlySource)
        let topMost = onlySource.filter { path in
            var parent = (path as NSString).deletingLastPathComponent
            while !parent.isEmpty {
                if sourceSet.contains(parent) { return false }
                parent = (parent as NSString).deletingLastPathComponent
            }
            return true
        }
        return (result.differs.map { SyncOperation(relativePath: $0, kind: .overwrite) }
            + topMost.map { SyncOperation(relativePath: $0, kind: .copy) })
            .sorted { $0.relativePath < $1.relativePath }
    }
}
