import Foundation

public struct ArchiveCatalog: Sendable {
    public let fileCount: Int
    public let hadSuspiciousPaths: Bool
    public let isPartial: Bool

    private let entriesByPath: [String: ArchiveEntry]
    private let childrenByParent: [String: [ArchiveEntry]]

    public init(parsed: ParsedCatalog) {
        var entriesByPath: [String: ArchiveEntry] = [:]
        var childrenByParent: [String: [ArchiveEntry]] = [:]
        var fileCount = 0

        for entry in parsed.entries {
            entriesByPath[entry.path] = entry
            childrenByParent[Self.parentPath(of: entry.path), default: []].append(entry)
            if !entry.isDirectory {
                fileCount += 1
            }
        }

        for (parent, children) in childrenByParent {
            childrenByParent[parent] = children.sorted(by: Self.archiveEntrySort)
        }

        self.entriesByPath = entriesByPath
        self.childrenByParent = childrenByParent
        self.fileCount = fileCount
        self.hadSuspiciousPaths = parsed.hadSuspiciousPaths
        self.isPartial = parsed.isPartial
    }

    public func children(of path: String) -> [ArchiveEntry] {
        childrenByParent[path] ?? []
    }

    public func entry(at path: String) -> ArchiveEntry? {
        entriesByPath[path]
    }

    public func descendantFiles(of path: String) -> [ArchiveEntry] {
        guard let entry = entriesByPath[path] else { return [] }
        if !entry.isDirectory { return [entry] }
        return entriesByPath.values
            .filter { !$0.isDirectory && Self.isDescendant($0.path, of: path) }
            .sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
    }

    private static func parentPath(of path: String) -> String {
        guard let slash = path.lastIndex(of: "/") else { return "" }
        return String(path[..<slash])
    }

    private static func archiveEntrySort(_ lhs: ArchiveEntry,
                                         _ rhs: ArchiveEntry) -> Bool {
        if lhs.isDirectory != rhs.isDirectory {
            return lhs.isDirectory
        }
        return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
    }

    private static func isDescendant(_ candidate: String, of folder: String) -> Bool {
        candidate.hasPrefix(folder + "/")
    }
}
