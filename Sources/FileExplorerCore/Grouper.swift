import Foundation

public struct FileGroup: Equatable, Sendable {
    public let title: String?
    public let entries: [FileEntry]

    public init(title: String?, entries: [FileEntry]) {
        self.title = title
        self.entries = entries
    }
}

public enum Grouper {
    public enum Axis: String, Codable, CaseIterable, Sendable {
        case none
        case kind
        case dateModified
        case size
    }

    public static func group(
        _ entries: [FileEntry],
        by axis: Axis,
        now: Date = Date()
    ) -> [FileGroup] {
        switch axis {
        case .none:
            return [FileGroup(title: nil, entries: entries)]
        case .kind:
            return groupByKind(entries)
        case .dateModified:
            return groupByDateModified(entries, now: now)
        case .size:
            return groupBySize(entries)
        }
    }

    private static func groupByKind(_ entries: [FileEntry]) -> [FileGroup] {
        let folderTitle = "Folder"
        let titles = Set(entries.map(\.kind)).sorted { lhs, rhs in
            if lhs == folderTitle { return true }
            if rhs == folderTitle { return false }
            return lhs.localizedStandardCompare(rhs) == .orderedAscending
        }
        return titles.map { title in
            FileGroup(title: title, entries: entries.filter { $0.kind == title })
        }
    }

    private static func groupByDateModified(
        _ entries: [FileEntry],
        now: Date
    ) -> [FileGroup] {
        let buckets: [(String, (TimeInterval) -> Bool)] = [
            ("Today", { $0 < 86_400 }),
            ("Yesterday", { $0 >= 86_400 && $0 < 2 * 86_400 }),
            ("Previous 7 Days", { $0 >= 2 * 86_400 && $0 < 7 * 86_400 }),
            ("Previous 30 Days", { $0 >= 7 * 86_400 && $0 < 30 * 86_400 }),
            ("Earlier", { $0 >= 30 * 86_400 }),
        ]
        return buckets.compactMap { title, contains in
            let grouped = entries.filter { contains(max(0, now.timeIntervalSince($0.modified))) }
            return grouped.isEmpty ? nil : FileGroup(title: title, entries: grouped)
        }
    }

    private static func groupBySize(_ entries: [FileEntry]) -> [FileGroup] {
        let mb = Int64(1_048_576)
        let gb = Int64(1_073_741_824)
        let buckets: [(String, (FileEntry) -> Bool)] = [
            (">1 GB", { !$0.isDirectory && $0.size > gb }),
            ("100 MB-1 GB", { !$0.isDirectory && $0.size >= 100 * mb && $0.size <= gb }),
            ("1-100 MB", { !$0.isDirectory && $0.size >= mb && $0.size < 100 * mb }),
            ("0-1 MB", { !$0.isDirectory && $0.size >= 0 && $0.size < mb }),
            ("Folders", { $0.isDirectory }),
        ]
        return buckets.compactMap { title, contains in
            let grouped = entries.filter(contains)
            return grouped.isEmpty ? nil : FileGroup(title: title, entries: grouped)
        }
    }
}
