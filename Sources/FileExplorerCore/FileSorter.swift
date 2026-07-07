import Foundation

public enum FileSorter {
    public static func sort(_ entries: [FileEntry],
                            using comparators: [KeyPathComparator<FileEntry>],
                            foldersFirst: Bool = true) -> [FileEntry] {
        let sorted = entries.sorted(using: comparators)
        guard foldersFirst else { return sorted }
        return sorted.filter(\.isDirectory) + sorted.filter { !$0.isDirectory }
    }
}
